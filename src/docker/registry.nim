##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Docker registry v2 wrapper
## https://docker-docs.uclv.cu/registry/spec/api/
## https://docker-docs.uclv.cu/registry/spec/manifest-v2-2/
## https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
## https://docs.docker.com/build/buildkit/toml-configuration/
## https://github.com/opencontainers/distribution-spec/blob/main/spec.md

import std/[
  nativesockets,
  net,
  options,
  os,
  strscans,
  uri,
]
import pkg/[
  nimutils/net,
  zippy/tarballs,
]
import ".."/[
  types,
  utils/bounded_http,
  utils/files,
  utils/ip,
  utils/json,
  utils/http,
  utils/sets,
  utils/strings,
  utils/times,
  utils/uri,
  utils/www_authenticate,
]
import "."/[
  exe,
  ids,
  json,
  nodes,
]

type
  RegistryResponseError* = object of ValueError
    ## `statusCode` is the HTTP status the registry answered with, or 0
    ## when the failure was not an HTTP status.
    statusCode*: int
  RegistryTlsError* = object of RegistryResponseError
  RegistryTimeoutError* = object of RegistryResponseError
  RegistryOversizedError* = object of RegistryResponseError
  RegistryReferrersError* = object of RegistryResponseError

  # depending on use, mirror is allowed to be used or not
  # for read-only docker can consult mirrors
  # whereas if it indents to write to the registry,
  # it only talks to the upstream registry
  RegistryUseCase* = enum
    ReadWrite
    ReadOnly # allows use of mirrors

  RegistryJsonCacheKey = tuple[image: DockerImage, httpMethod: HttpMethod,
                               path: string, useCase: RegistryUseCase, requireSameOrigin: bool]

  RegistryAccess* = ref object
    ## Registry HTTP state isolated to one operation.
    discoverDocker*:       bool
    authFile*:             string
    authConfig*:           JsonNode
    budget*:               Option[HttpBudget]
    strictReferrerLinks*:  bool
    lastRequestUri*:       Uri
    configByRegistry*:     Table[(RegistryUseCase, string), RegistryConfig]
    jsonCache*:            Table[RegistryJsonCacheKey, (string, Response, Uri)]
    referrersCache*:       Table[string, bool]

  RegistryConfig = ref object
    source*:      string
    scheme*:      string
    registry*:    string
    mirroring*:   string
    prefix*:      string
    project*:     string
    certPath*:    string
    pinnedCert*:  string
    verifyMode*:  SslCVerifyMode
    auth*:        TableRef[string, string]                      # by namespace
    wwwAuth*:     TableRef[string, TableRef[bool, HttpHeaders]] # by repo, httpmethod in HEAD,GET
    fallthrough*: bool # whether to fallthrough to next config on http errors

const
  TIMEOUT = 3000 # ms

proc newRegistryAccess(): RegistryAccess =
  RegistryAccess(
    discoverDocker:   true,
    budget:           none(HttpBudget),
    configByRegistry: initTable[(RegistryUseCase, string), RegistryConfig](),
    jsonCache:        initTable[RegistryJsonCacheKey, (string, Response, Uri)](),
    referrersCache:   initTable[string, bool](),
  )

proc loadRegistryAuthFile(path: string): JsonNode =
  result = newJObject()
  if path == "":
    return
  try:
    let data = tryToLoadFile(path)
    if data == "":
      return
    result = parseJson(data).assertIs(JObject, "bad registry auth file type")
  except:
    trace("registry: could not read auth file " & path & " due to: " &
          getCurrentExceptionMsg())

proc newAuthFileRegistryAccess*(authFile = ""): RegistryAccess =
  ## Registry HTTP that uses only `authFile` or `REGISTRY_AUTH_FILE`.
  ## Does not read Docker daemon, Buildx, or ~/.docker/config.json.
  var path = authFile
  if path == "":
    path = getEnv("REGISTRY_AUTH_FILE")
  result = newRegistryAccess()
  result.discoverDocker = false
  result.authFile = path
  result.authConfig = loadRegistryAuthFile(path)

var
  dockerRegistryAccess* = newRegistryAccess()
  currentRegistryAccess = dockerRegistryAccess

proc registryUsesDockerDiscovery*(): bool =
  currentRegistryAccess.discoverDocker

template withRegistryAccess*(access: RegistryAccess, body: untyped) =
  let previousAccess = currentRegistryAccess
  currentRegistryAccess = access
  try:
    body
  finally:
    currentRegistryAccess = previousAccess

const
  CONTENT_TYPE_MAPPING* = {
    "application/vnd.docker.distribution.manifest.list.v2+json": DockerManifestType.list,
    "application/vnd.docker.distribution.manifest.v2+json": DockerManifestType.image,
    "application/vnd.docker.container.image.v1+json": DockerManifestType.config,
    "application/vnd.docker.image.rootfs.diff.tar.gzip": DockerManifestType.layer,

    "application/vnd.oci.image.index.v1+json": DockerManifestType.list,
    "application/vnd.oci.image.manifest.v1+json": DockerManifestType.image,
    "application/vnd.oci.image.config.v1+json": DockerManifestType.config,

    "application/octet-stream": DockerManifestType.layer,
  }.toTable()
  MEGABYTE = 1 shl 20

proc uses(useCase: RegistryUseCase): seq[RegistryUseCase] =
  ## which uses lookups are applicable for the registry use
  ## ReadOnly use can only be used for reads
  ## however ReadWrite use can be used for both
  result.add(useCase)
  if useCase == RegistryUseCase.ReadWrite:
    result.add(RegistryUseCase.ReadOnly)

proc usesWwwAuth(self: RegistryConfig): bool =
  for _, auth in self.wwwAuth.pairs():
    for _, httpMethod in auth.pairs():
      if len(httpMethod) > 0:
        return true
  return false

proc uri(self: RegistryConfig): Uri =
  return parseUri(self.scheme & self.registry)

proc authJson(access: RegistryAccess): JsonNode =
  if access.authConfig != nil:
    return access.authConfig
  return getDockerAuthConfig()

proc withAuth(self: RegistryConfig): RegistryConfig =
  result       = self
  self.wwwAuth = newTable[string, TableRef[bool, HttpHeaders]]()
  self.auth    = newTable[string, string]()
  let
    uri        = self.uri().withPort()
    config     = currentRegistryAccess.authJson()
  if "auths" notin config:
    return
  try:
    for k, v in config{"auths"}.assertIs(JObject, "bad auths type").pairs():
      let authUri = parseUriDefaultScheme(k).withDefaultPort(uri.port)
      if authUri.registry() == uri.registry():
        let token = v{"auth"}.getStr()
        if token != "":
          let namespace = authUri.authNamespace()
          self.auth[namespace] = token
          trace("docker: " & self.registry & " - found basic auth for " & k)
  except:
    trace("docker: invalid auth config: " & getCurrentExceptionMsg())

proc authHeadersFor(self: RegistryConfig, image: DockerImage): HttpHeaders =
  result = newHttpHeaders()
  if len(self.auth) == 0:
    return
  let parts = image.name.split('/')
  for i in countdown(len(parts), 0):
    let namespace = parts[0..<i].join("/")
    if namespace in self.auth:
      return newHttpHeaders(@[
        ("Authorization", "Basic " & self.auth[namespace]),
      ])

proc iterDaemonSpecificRegistryConfigs(self:         DockerImage,
                                       withHttp    = true,
                                       prefix      = "",
                                       mirroring   = "",
                                       fallthrough = false,
                                       ): seq[() -> seq[RegistryConfig]] =
  result.add(proc (): seq[RegistryConfig] =
    result.add(RegistryConfig(
      source:      "daemon",
      scheme:      "https://",
      registry:    self.registry,
      prefix:      prefix,
      verifyMode:  CVerifyPeer,
      mirroring:   mirroring,
      fallthrough: fallthrough,
    ))
  )

  result.add(proc(): seq[RegistryConfig] =
    var (path, cert) =
      try:
        readFirstDockerHostFile(@[
          "/etc/docker/certs.d/" & self.registry & "/ca.crt",
          "/etc/docker/certs.d/" & self.domain   & "/ca.crt",
        ])
      except:
        ("", "")
    if cert != "":
      trace("docker: found CA certificate for " & self.registry & " at " & path & " in docker daemon")
      result.add(RegistryConfig(
        source:      "daemon",
        scheme:      "https://",
        registry:    self.registry,
        prefix:      prefix,
        verifyMode:  CVerifyPeer,
        mirroring:   mirroring,
        fallthrough: fallthrough,
        certPath:    path,
        pinnedCert:  writeNewTempFile(
          cert,
          prefix = self.domain,
          suffix = ".crt",
        ),
      ))
  )

  result.add(proc: seq[RegistryConfig] =
    for i in getDockerInfoSubList("insecure registries:"):
      if self.registry == i or self.domain == i:
        trace("docker: " & i & " is configured as an insecure registry in docker daemon")
        trace("docker: " & self.registry & " will attempt TLS without verifying server cert")
        result.add(RegistryConfig(
          source:      "daemon",
          scheme:      "https://",
          registry:    self.registry,
          prefix:      prefix,
          verifyMode:  CVerifyNone,
          mirroring:   mirroring,
          fallthrough: fallthrough,
        ))
        if withHttp:
          result.add(RegistryConfig(
            source:      "daemon",
            scheme:      "http://",
            registry:    self.registry,
            prefix:      prefix,
            verifyMode:  CVerifyNone,
            mirroring:   mirroring,
            fallthrough: fallthrough,
          ))
      else:
        # docker does not support port numbers along with cidr blocks
        # so 127.0.0.0/8 cannot be combined with a port number
        # like 127.0.0.0/8:1234
        if ":" in i:
          continue
        try:
          let
            # if the domain is not an ip address, it raises an excpetion
            # and which we ignore which is fine
            (ip, ipRange)   = parseIpCidr(i)
            # when the insecure registry is a cidr block
            # any domain resolved to that block is insecure
            selfIp =
              try:
                parseIpAddress(self.domain)
              except:
                parseIpAddress(getHostByName(self.domain).addrList[0])
          trace("docker: checking if " & self.domain & " (" & $selfIp & ") is within " & $i)
          if selfIp.family != ip.family:
            continue
          if selfIp in ipRange:
            trace("docker: " & self.domain & " (" & $selfIp & ") is an insecure registry via IP address match for " & i)
            trace("docker: " & self.registry & " will attempt TLS without verifying server cert")
            result.add(RegistryConfig(
              source:      "daemon",
              scheme:      "https://",
              registry:    self.registry,
              prefix:      prefix,
              verifyMode:  CVerifyNone,
              mirroring:   mirroring,
              fallthrough: fallthrough,
            ))
            if withHttp:
              trace("docker: " & self.registry & " will attempt http")
              result.add(RegistryConfig(
                source:      "daemon",
                scheme:      "http://",
                registry:    self.registry,
                prefix:      prefix,
                verifyMode:  CVerifyNone,
                mirroring:   mirroring,
                fallthrough: fallthrough,
              ))
        except:
          continue
  )

proc iterDaemonRegistryConfigs(self: DockerImage,
                               useCase: RegistryUseCase,
                               ): seq[() -> seq[() -> seq[RegistryConfig]]] =
  # docker daemon only suports docker hub mirror
  if useCase == RegistryUseCase.ReadOnly and self.isDockerHub():
    result.add(proc (): seq[() -> seq[RegistryConfig]] =
      for mirror in getDockerInfoSubList("registry mirrors:"):
        trace("docker: attempting to use docker hub mirror: " & mirror)
        let
          mirrorUri = parseUri(mirror)
          registry  = mirrorUri.registry
          prefix    = mirrorUri.path
          mirrored  = self.withRegistry(registry)
        # mirror is to the same thing. skip
        if registry == self.registry:
          trace("docker: mirror is using docker hub itself. skipping")
          continue
        if mirrorUri.scheme == "https":
          result &= mirrored.iterDaemonSpecificRegistryConfigs(
            withHttp    = false,
            prefix      = prefix,
            mirroring   = self.registry,
            fallthrough = true,
          )
        else:
          result.add(proc (): seq[RegistryConfig] =
            result.add(RegistryConfig(
              source:      "daemon",
              scheme:      "http://",
              registry:    registry,
              prefix:      prefix,
              verifyMode:  CVerifyNone,
              mirroring:   self.registry,
              fallthrough: true,
            ))
          )
    )

  result.add(proc (): seq[() -> seq[RegistryConfig]] =
    result.add(self.iterDaemonSpecificRegistryConfigs())
  )

proc findRegistry(self: JsonNode, registry: string): JsonNode =
  if "registry" notin self:
    return nil
  for r in registry.registryAliases():
    if r in self{"registry"}:
      return self["registry"][r]
  return nil

proc iterBuildxSpecificRegistryConfigs(self:         DockerImage,
                                       node:         string,
                                       config:       JsonNode,
                                       mirroring   = "",
                                       project     = "",
                                       fallthrough = false,
                                       ): seq[() -> seq[RegistryConfig]] =
  let registry = config.findRegistry(self.registry)
  if registry == nil:
    return
  let
    http     = registry{"http"}.getBool()
    insecure = registry{"insecure"}.getBool()
    certs    = registry{"ca"}
  if not insecure and not http:
    result.add(proc (): seq[RegistryConfig] =
      result.add(RegistryConfig(
        source:      "buildx",
        scheme:      "https://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyPeer,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      ))
    )
  if certs != nil and certs.kind == JArray:
    for cert in certs:
      result.add(proc (): seq[RegistryConfig] =
        let path = cert.getStr()
        try:
          let data = dockerInvocation.readBuilderNodeFile(node, path)
          trace("docker: found CA certificate for " & self.registry & " at " & path & " in buildx node " & node)
          result.add(RegistryConfig(
            source:      "buildx",
            scheme:      "https://",
            registry:    self.registry,
            project:     project,
            verifyMode:  CVerifyPeer,
            mirroring:   mirroring,
            fallthrough: fallthrough,
            certPath:    path,
            pinnedCert:  writeNewTempFile(
              data,
              prefix = self.domain,
              suffix = ".crt",
            ),
          ))
        except:
          trace("docker: cannot read buildx registry CA from " & path & " in buildx node " & node)
      )
  if insecure:
    result.add(proc (): seq[RegistryConfig] =
      trace("docker: " & self.registry & " is configured as an insecure registry in docker buildx node " & node)
      result.add(RegistryConfig(
        source:      "buildx",
        scheme:      "https://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyNone,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      ))
    )
  if http:
    result.add(proc (): seq[RegistryConfig] =
      trace("docker: " & self.registry & " is configured as an http registry in docker buildx node " & node)
      result.add(RegistryConfig(
        source:      "buildx",
        scheme:      "http://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyNone,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      ))
    )

proc iterBuildxRegistryConfigs(self: DockerImage,
                               useCase: RegistryUseCase,
                               ): seq[() -> seq[() -> seq[RegistryConfig]]] =
  if hasBuildX() and useCase == RegistryUseCase.ReadOnly:
    result.add(proc (): seq[() -> seq[RegistryConfig]] =
      for node, config in dockerInvocation.iterBuilderNodesConfigs():
        try:
          let rconfig = config.findRegistry(self.registry)
          if rconfig == nil:
            continue
          let mirrors  = rconfig{"mirrors"}
          if mirrors == nil or mirrors.kind != JArray:
            continue
          for m in mirrors:
            let mirror = m.getStr()
            trace("docker: for registry " & self.registry & " attempting to use mirror: " & mirror)
            let
              mirrorUri = parseUri("https://" & mirror)
              registry  = mirrorUri.registry
              project   = mirrorUri.path
              mirrored  = self.withRegistry(registry)
            # mirror is to the same thing. skip
            if registry == self.registry:
              trace("docker: mirror is to itself. skipping")
              continue
            try:
              result.add(mirrored.iterBuildxSpecificRegistryConfigs(
                node,
                config,
                project     = project,
                mirroring   = self.registry,
                fallthrough = true,
              ))
            except:
              trace("docker: cannot inspect buildx mirror " & mirror & " config due to: " & getCurrentExceptionMsg())
              continue
        except:
          trace("docker: cannot inspect buildx mirror config due to: " & getCurrentExceptionMsg())
          continue
    )

  result.add(proc (): seq[() -> seq[RegistryConfig]] =
    result.add(proc (): seq[RegistryConfig] =
      # try most secure config just in case it works
      # to avoid parsing configs when use is readwrite
      result.add(RegistryConfig(
        source:      "buildx",
        scheme:      "https://",
        registry:    self.registry,
        verifyMode:  CVerifyPeer,
      ))
    )
  )

  result.add(proc (): seq[() -> seq[RegistryConfig]] =
    for node, config in dockerInvocation.iterBuilderNodesConfigs():
      try:
        result.add(self.iterBuildxSpecificRegistryConfigs(node, config))
      except:
        trace("docker: cannot inspect buildx config due to: " & getCurrentExceptionMsg())
  )

iterator getConfigs(self: DockerImage, useCase: RegistryUseCase): RegistryConfig =
  ## get all plausible configs for iteracting with the registry
  ## note this is explicitly implemented as an iterator
  ## as getting specific config can be more expensive as it might
  ## need to get docker daemon/buildx configs/etc
  ## and iterators allow to make that lazy where if a config attempt
  ## fails, only then next config is fetched until a working config
  ## is found
  var
    cached = RegistryConfig(nil)
    # some configs could be duplicates such as if there are multiple buildx
    # nodex they might all have equivalent configs
    checkedConfigs = newSeq[RegistryConfig]()
    access = currentRegistryAccess

  if (useCase, self.registry) in access.configByRegistry:
    cached = access.configByRegistry[(useCase, self.registry)]
    checkedConfigs.add(cached)
    yield cached

  # if the cached registry config is a mirror,
  # we need to provide a way to fallthrough to upstream registry
  if cached == nil or cached.fallthrough:
    if not access.discoverDocker:
      let httpsConfig = RegistryConfig(
        source:     "authfile",
        scheme:     "https://",
        registry:   self.registry,
        verifyMode: CVerifyPeer,
      ).withAuth()
      if httpsConfig notin checkedConfigs:
        checkedConfigs.add(httpsConfig)
        yield httpsConfig
      if self.domain in ["localhost", "127.0.0.1", "[::1]"]:
        let httpConfig = RegistryConfig(
          source:     "authfile",
          scheme:     "http://",
          registry:   self.registry,
          verifyMode: CVerifyNone,
        ).withAuth()
        if httpConfig notin checkedConfigs:
          yield httpConfig
    else:
      let isBuildx = (
        dockerInvocation != nil and
        dockerInvocation.cmd == build and
        dockerInvocation.foundBuildx
      )
      template generateConfigs(generators: seq[() -> seq[() -> seq[RegistryConfig]]]) =
        for generator in generators:
          try:
            let generated = generator()
            for configGenerator in generated:
              try:
                let configs = configGenerator()
                for config in configs:
                  if config notin checkedConfigs:
                    let config = config.withAuth()
                    checkedConfigs.add(config)
                    yield config
              except:
                trace("docker: " & getCurrentExceptionMsg())
          except:
            trace("docker: " & getCurrentExceptionMsg())
      # when running buildx, buildx nodes configs should take precedence
      # over daemon configs but we still scan both just in case
      if isBuildx:
        generateConfigs(self.iterBuildxRegistryConfigs(useCase = useCase))
      generateConfigs(self.iterDaemonRegistryConfigs(useCase = useCase))
      if not isBuildx:
        generateConfigs(self.iterBuildxRegistryConfigs(useCase = useCase))

proc checkReferrersSupport(image: DockerImage, response: Response) =
  if not response.headers.hasKey("OCI-Subject"):
    return
  let key = image.withBare().asRepoRef()
  currentRegistryAccess.referrersCache[key] = true

proc request(self:              DockerImage,
             httpMethod:        HttpMethod,
             path               = "",
             url                = initUri(),
             accept             = "",
             contentType        = "",
             useCase            = RegistryUseCase.ReadOnly,
             body               = "",
             range              = 0 .. 0,
             size               = 0,
             timeout            = TIMEOUT,
             requireSameOrigin  = false,
             acceptStatusCodes: openArray[Slice[int]] = @[200..299],
             ): (string, Response) =
  let
    access   = currentRegistryAccess
    cacheKey = (self, httpMethod, path & "\t" & $url, useCase, requireSameOrigin)
  if not access.discoverDocker and access.budget.isNone():
    access.budget = some(HttpBudget(
      deadline: getMonoTime() + initDuration(seconds = 30),
      maxBodyBytes: 32 * 1024 * 1024,
    ))
  if cacheKey in access.jsonCache:
    let (message, response, effectiveUri) = access.jsonCache[cacheKey]
    access.lastRequestUri = effectiveUri
    return (message, response)
  var
    failure:       ref RegistryResponseError
    ignoredErrors: seq[string] = @[]
  for config in self.getConfigs(useCase = useCase):
    let
      normalized = (
        self
        .withRegistry(config.registry)
        .withProject(config.project)
      )
      defaultUri = normalized.uri(
        scheme  = config.scheme,
        prefix  = config.prefix,
        path    = path,
      )
      uri = combine(defaultUri, url)
    var msg = $useCase & " " & $httpMethod & " " & $uri
    if uri.scheme == "https":
      msg &= " " & $config.verifyMode
      if config.certPath != "":
        msg &= "@" & config.certPath
    try:
      var headers = newHttpHeaders()
      if accept != "":
        headers["Accept"] = accept
      if body != "":
        if contentType != "":
          headers["Content-Type"] = contentType
        # OCI distribution spec requires "{first}-{last}" format (no "bytes " prefix,
        # no "/{total}" suffix). See:
        # https://github.com/opencontainers/distribution-spec/blob/main/spec.md#pushing-blobs
        # Only include for chunked uploads; omit for monolithic uploads because
        # some registries (e.g. ghcr) reject Content-Range on monolithic PUT.
        let
          hasRange    = range.a > 0 or range.b > 0
          isPartial   = range.b - range.a + 1 != size
        if hasRange and isPartial:
          headers["Content-Range"] = $range.a & "-" & $range.b
        headers["Content-Length"] = $len(body)
      for k, v in headers.pairs():
        msg &= " " & k & ":" & v
      trace("docker: " & msg)
      if requireSameOrigin and not sameOrigin(uri, defaultUri):
        raise newException(HttpOriginError, "referrer pagination left the registry origin")
      let
        isGet = httpMethod in [HttpHead, HttpGet]
        sendConfigAuth = access.discoverDocker or sameOrigin(uri, defaultUri)
        wwwAuth = (
          config.wwwAuth
          .mgetOrPut(normalized.repo, newTable[bool, HttpHeaders]())
          .mgetOrPut(isGet,           newHttpHeaders())
        )
        requestHeaders = headers
      if sendConfigAuth:
        discard requestHeaders.update(config.authHeadersFor(normalized)).update(wwwAuth)
      let (authHeaders, response, effectiveUri) =
        if access.budget.isSome():
          authHeadersBoundedRequest(
            uri, httpMethod, access.budget.get(),
            body              = body,
            headers           = requestHeaders,
            pinnedCert        = config.pinnedCert,
            verifyMode        = config.verifyMode,
            sameOriginRedirects = requireSameOrigin,
            acceptStatusCodes = acceptStatusCodes,
          )
        else:
          let (auth, response) = authHeadersSafeRequest(
            uri, httpMethod,
            body              = body,
            headers           = requestHeaders,
            pinnedCert        = config.pinnedCert,
            verifyMode        = config.verifyMode,
            timeout           = timeout,
            retries           = 2,
            connectRetries    = 2,
            acceptStatusCodes = acceptStatusCodes,
          )
          (auth, response, uri)
      if sendConfigAuth:
        config.wwwAuth[normalized.repo][isGet] = wwwAuth.update(authHeaders)
      var respMsg = "docker: " & $response.status
      for k, v in response.headers.pairs():
        if k notin ["authorization"]:
          respMsg &= " " & k & ":" & v
      trace(respMsg)
      for u in useCase.uses():
        discard access.configByRegistry.hasKeyOrPut((u, normalized.registry), config)
        discard access.configByRegistry.hasKeyOrPut((u, self.registry), config)
      access.lastRequestUri = effectiveUri
      if isGet:
        access.jsonCache[cacheKey] = (msg, response, effectiveUri)
      return (msg, response)
    # exceptions cannot be raised from inside this loop as the config
    # iterator catches them; a definitive failure is kept and raised after it
    except HttpTlsProtocolError:
      ignoredErrors.add("registry endpoint did not complete TLS")
    except HttpTlsError as error:
      failure = (ref RegistryTlsError)(msg: error.msg)
      break
    except HttpOriginError:
      failure = (ref RegistryReferrersError)(msg: "referrer pagination left the registry origin")
      break
    except SslError as error:
      if not access.discoverDocker and not isTlsProtocolMismatch(error.msg):
        failure = (ref RegistryTlsError)(msg: "registry TLS peer identity verification failed")
        break
      ignoredErrors.add(error.msg)
    except HttpDeadlineError:
      failure = (ref RegistryTimeoutError)(msg: "registry request timed out")
      break
    except HttpBodyTooLargeError:
      failure = (ref RegistryOversizedError)(msg: "registry response exceeds the size limit")
      break
    except ValueError as e:
      if not access.discoverDocker and not (e of HttpStatusError):
        failure = (ref RegistryResponseError)(msg: e.msg)
        break
      # A final HTTP status identifies the selected non-mirror registry.
      # for non-mirror registry:
      # as we can talk to the registry, any errors from this point on
      # mean image doesnt exist in the registry or invalid config such as
      # invalid auth which we cant improve even if we attempt other configs
      # for mirror registry:
      # as mirror might be missing the image, on 404s docker reattempts
      # to fetch the image from upstream registry bypassing the mirror
      # hence we need to fallthrough to the next config
      if config.fallthrough:
        trace("docker: ignoring error: " & e.msg)
        ignoredErrors.add(e.msg)
      else:
        for u in useCase.uses():
          discard access.configByRegistry.hasKeyOrPut((u, normalized.registry), config)
          discard access.configByRegistry.hasKeyOrPut((u, self.registry), config)
        failure = (ref RegistryResponseError)(
          msg:        e.msg,
          statusCode: (if e of HttpStatusError: (ref HttpStatusError)(e).code else: 0),
        )
        break
    except:
      if not access.discoverDocker:
        failure = newException(RegistryResponseError, "registry transport request failed")
        break
      let msg = getCurrentExceptionMsg()
      trace("docker: ignoring error: " & msg)
      ignoredErrors.add(msg)
  if failure != nil:
    raise failure
  var errMsg = "could not find working registry configuration for " & $self
  if ignoredErrors.len > 0:
    errMsg &= ": " & ignoredErrors.join("; ")
  if not access.discoverDocker:
    raise newException(RegistryResponseError, "registry transport request failed")
  raise newException(ValueError, errMsg)

proc validateDigest(digest: string): string =
  if not digest.startsWith("sha256:") or digest.len != 71:
    raise newException(ValueError, "invalid digest from registry: " & digest)
  for c in digest[7 .. ^1]:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      raise newException(ValueError, "invalid digest from registry: " & digest)
  return digest

proc manifestHead*(image:    DockerImage,
                   useCase = RegistryUseCase.ReadOnly,
                   ): DockerDigestedJson =
  let
    (_, response) = image.request(
      useCase    = useCase,
      httpMethod = HttpHead,
      path       = "/manifests/" & image.imageRef,
      accept     = (
        "application/vnd.docker.distribution.manifest.v2+json, " &
        "application/vnd.docker.distribution.manifest.list.v2+json, " &
        "application/vnd.oci.image.manifest.v1+json, " &
        "application/vnd.oci.image.index.v1+json, " &
        "*/*"
      ),
    )
    contentType = response.headers.mustGet("Content-Type", "registry HEAD response missing Content-Type header")
    digest      = validateDigest(response.headers.mustGet("Docker-Content-Digest", "registry HEAD response missing Docker-Content-Digest header"))
  # HEAD normally doesnt return referrers header but checking just in-case
  checkReferrersSupport(image, response)
  let size = response.headers.mustGetInt(
    "Content-Length",
    "registry HEAD response missing Content-Length header",
  )
  return newDockerDigestedJson(
    data      = JsonNode(nil),
    digest    = digest,
    mediaType = contentType,
    size      = size,
  )

proc manifestGet*(image:    DockerImage,
                  accept:   string,
                  useCase = RegistryUseCase.ReadOnly,
                  ): DockerDigestedJson =
  let (_, response) = image.request(
    useCase    = useCase,
    httpMethod = HttpGet,
    path       = "/manifests/" & image.imageRef,
    accept     = accept,
  )
  # GET normally doesnt return referrers header but checking just in-case
  checkReferrersSupport(image, response)
  return newDockerDigestedJson(
    data      = response.body(),
    digest    = response.body().sha256Hex(),
    mediaType = accept,
  )

proc layerGetString*(layer:    DockerImage,
                     accept:   string,
                     useCase = RegistryUseCase.ReadOnly,
                     ): string =
  let
    (_, response) = layer.request(
      useCase    = useCase,
      httpMethod = HttpGet,
      path       = "/blobs/" & layer.imageRef,
      accept     = accept,
    )
  return response.body()

proc layerGetJson*(layer:    DockerImage,
                   accept:   string,
                   useCase = RegistryUseCase.ReadOnly,
                   ): DigestedJson =
  return parseAndDigestJson(
    layer.layerGetString(
      useCase = useCase,
      accept  = accept,
    ),
    digest = layer.imageRef,
  )

proc layerGetFileString*(layer:    DockerImage,
                         name:     string,
                         accept:   string,
                         useCase = RegistryUseCase.ReadOnly,
                         ): string =
  trace("docker: extracting " & name & " from layer " & $layer)
  let
    response = layer.layerGetString(
      useCase = useCase,
      accept  = accept,
    )
    tarPath = writeNewTempFile(response, suffix = name)
  let
    # extract needs non-existing path so doing one more joinPath
    untarPath = getNewTempDir().joinPath(layer.digest)
    namePath  = untarPath.joinPath(name)
  extractAll(tarPath, untarPath)
  result = tryToLoadFile(namePath)

proc layerPutStart(layer: DockerImage): tuple[location: Uri, minChunkSize: int] =
  let (_, initResponse) = layer.request(
    useCase     = RegistryUseCase.ReadWrite,
    httpMethod  = HttpPost,
    path        = "/blobs/uploads/",
    contentType = "application/octet-stream",
  )
  var location: Uri
  try:
    location = parseUri(initResponse.headers["Location"])
  except:
    raise newException(
      ValueError,
      "could not determine layer upload url due to: " & getCurrentExceptionMsg()
    )
  if not location.path.startsWith("/"):
    raise newException(
      ValueError,
      "upload Location is expected to be absolute path. Got: " & location.path
    )
  let minChunkSize =
    if initResponse.headers.hasKey("oci-chunk-min-length"):
      try:
        max(0, parseInt(initResponse.headers["oci-chunk-min-length"]))
      except:
        0
    else:
      0
  return (location, minChunkSize)

proc nextStartAt(response: Response, startAt: int, attempts: int, retries = 2): (int, int) =
  if not response.headers.hasKey("Range"):
    raise newException(
      ValueError,
      "could not upload layer as reponse doesnt have expected Range header"
    )
  # accept both OCI "N-M" and RFC 7233 "bytes=N-M" formats
  let raw = response.headers["Range"].removePrefix("bytes=")
  let (validRange, _, rangeEnd) = raw.scanTuple("$i-$i")
  if not validRange:
    raise newException(
      ValueError,
      "could not upload as Range response header is not valid format <start>-<end>: " &
      response.headers["Range"]
    )
  let nextStartAt = rangeEnd + 1
  if nextStartAt < startAt:
    raise newException(
      ValueError,
      "could not upload layer as Range response header went backwards: " &
      response.headers["Range"]
    )
  var attempts = attempts
  if nextStartAt == startAt:
    attempts += 1
  else:
    attempts = 1
  return (nextStartAt, attempts)

proc nextChunkOffset(
    response:          Response,
    startAt:           int,
    endAt:             int,
    attempts:          int,
    trustSentPosition: bool,
): (int, int, bool) =
  ## Decide the next (startAt, attempts, trustSentPosition) after a chunk
  ## upload response.
  ##
  ## On a 416 in sent-position mode: the registry's Range header cannot be
  ## trusted in general, but a 416 whose Range points *within* the chunk we
  ## just sent (rangeEnd+1 > startAt) means the registry partially stored the
  ## chunk and is giving us a real resume offset - honor it. If Range is at or
  ## before startAt the registry is hallucinating (the same stale value that
  ## engaged the latch), so raise immediately rather than retrying blind.
  if response.code() == Http416:
    if trustSentPosition:
      if not response.headers.hasKey("Range"):
        raise newException(
          ValueError,
          "could not upload layer: 416 in sent-position mode missing Range header",
        )
      let raw = response.headers["Range"].removePrefix("bytes=")
      let (validRange, _, rangeEnd) = raw.scanTuple("$i-$i")
      if not validRange:
        raise newException(
          ValueError,
          "could not upload layer: 416 in sent-position mode with invalid Range: " &
          response.headers["Range"],
        )
      let nextAt = rangeEnd + 1
      if nextAt > startAt:
        return (nextAt, 1, true)
      raise newException(
        ValueError,
        "could not upload layer: 416 in sent-position mode with stale Range " &
        response.headers["Range"] & " at position " & $startAt,
      )
    let (nextAt, tries) = response.nextStartAt(startAt, attempts)
    if tries > 2:
      raise newException(
        ValueError,
        "could not upload layer: registry rejected chunk at position " &
        $nextAt & " after " & $tries & " attempts",
      )
    return (nextAt, tries, false)
  if trustSentPosition or not response.headers.hasKey("Range"):
    return (endAt + 1, 1, trustSentPosition)
  let (nextAt, tries) = response.nextStartAt(startAt, attempts)
  if tries > 2:
    return (endAt + 1, 1, true)
  return (nextAt, tries, false)

proc finalizeBlobDigest(response: Response, layer: DockerImage): string =
  ## Sanity-check the Docker-Content-Digest returned by the registry against
  ## the locally computed layer digest.
  ##
  ## Per the OCI Distribution Specification, registries MUST verify uploaded
  ## blob content against the digest provided in the finalize PUT ?digest=
  ## parameter and MUST return DIGEST_INVALID (400) on mismatch:
  ##   "Clients MUST include a digest parameter in the query string of the
  ##    final chunk. The registry MUST verify the content against the provided
  ##    digest."
  ## https://github.com/opencontainers/distribution-spec/blob/main/spec.md
  ##
  ## A compliant registry therefore already enforces correctness at the
  ## finalize step and this comparison is redundant for it.  However, a
  ## non-compliant registry may skip enforcement and simply echo back the
  ## digest submitted in the ?digest= query parameter - in which case this
  ## comparison always passes regardless of what bytes were actually stored.
  ## This is therefore a sanity check that catches honest-but-buggy registries
  ## and proxies, not a cooperation-independent integrity guarantee.
  result = validateDigest(
    response.headers.mustGet(
      "Docker-Content-Digest",
      "registry PUT response missing Docker-Content-Digest header",
    )
  )
  if result.extractDockerHash() != layer.digest:
    raise newException(
      ValueError,
      "registry-reported blob digest " & result &
      " does not match uploaded layer digest sha256:" & layer.digest,
    )

proc chunkUploadTarget(
    location: Uri,
    layer:    DockerImage,
    isFinal:  bool,
): (HttpMethod, Uri) =
  ## Derive the per-chunk request method and URL from the stable upload
  ## `location`. The final chunk finalizes the blob with a content-addressed
  ## PUT carrying ?digest=; every other chunk streams with PATCH. The digest is
  ## added here, at the call site, against a fresh copy of the immutable base
  ## location rather than mutated onto a shared `location`, so a re-looped final
  ## attempt cannot stack a second ?digest= pair (withQueryPair appends, never
  ## replaces) nor leak the finalize query onto a non-final PATCH.
  if isFinal:
    (HttpPut, location.withQueryPair("digest", layer.imageRef))
  else:
    (HttpPatch, location)

proc layerPutFileStream*(
    layer:       DockerImage,
    contentType: string,
    fileStream:  FileStringStream,
): DockerDigestedJson =
  let
    layer          = if layer.digest != "": layer
                     else: layer.withDigest(fileStream.sha256Hex())
    size           = len(fileStream)
    # fyi docker cli seems to upload as monolithic upload :shrug:
    chunkSize      = int(attrGet[Con4mSize]("docker.registry_layer_chunk_size"))
    layerTimeoutMs = int(attrGet[Con4mDuration]("docker.registry_layer_upload_timeout")) div 1000
  try:
    let (_, response) = layer.request(
      useCase     = RegistryUseCase.ReadWrite,
      httpMethod  = HttpHead,
      path        = "/blobs/" & layer.imageRef,
      accept      = contentType,
    )
    trace("docker: layer already exists. nothing to upload")
    let existingSize = response.headers.mustGetInt(
      "Content-Length",
      "registry HEAD response missing Content-Length header",
    )
    return newDockerDigestedJson(
      data      = JsonNode(nil),
      digest    = layer.digest,
      mediaType = response.headers.mustGet("Content-Type", "registry HEAD response missing Content-Type header"),
      size      = existingSize,
    )
  except RegistryResponseError:
    trace("docker: layer doesnt exist. uploading " & $layer)
    if size == 0:
      raise newException(ValueError, "cannot upload zero-sized layer for " & $layer)
    var
      (location, minChunkSize) = layer.layerPutStart()
      effectiveChunkSize       = max(chunkSize, minChunkSize)
      startAt                  = 0
      attempts                 = 1
      trustSentPosition        = false
      response:                  Response
    while startAt < size:
      let
        endAt                    = min(startAt + effectiveChunkSize, size) - 1
        isFinal                  = endAt == size - 1
        (httpMethod, requestUrl) = chunkUploadTarget(location, layer, isFinal)
      try:
        (_, response) = layer.request(
          useCase           = RegistryUseCase.ReadWrite,
          httpMethod        = httpMethod,
          url               = requestUrl,
          body              = fileStream[startAt..endAt],
          range             = startAt..endAt,
          size              = size,
          contentType       = "application/octet-stream",
          acceptStatusCodes = [200..299, 416..416],
          timeout           = layerTimeoutMs,
        )
      except:
        raise newException(
          ValueError,
          "could not upload layer due to: " & getCurrentExceptionMsg()
        )
      if response.code() == Http416:
        trace("docker: chunk not fully uploaded: " & response.body())
      let wasTrusting = trustSentPosition
      (startAt, attempts, trustSentPosition) = response.nextChunkOffset(
        startAt           = startAt,
        endAt             = endAt,
        attempts          = attempts,
        trustSentPosition = trustSentPosition,
      )
      if trustSentPosition and not wasTrusting:
        # Range not advancing after retries - registry accepted the chunks
        # but reports stale Range values (seen on ECR, which stores data
        # correctly but delays Range updates).  Switch to tracking position
        # by what we sent rather than what the registry reports.
        # https://github.com/aws/containers-roadmap/issues/2831
        trace("docker: Range not advancing, switching to sent-position tracking")
      if response.headers.hasKey("Location"):
        location = parseUri(response.headers["Location"])
    return newDockerDigestedJson(
      data      = JsonNode(nil),
      digest    = response.finalizeBlobDigest(layer),
      mediaType = contentType,
      size      = len(fileStream),
    )

proc layerPutString*(layer:       DockerImage,
                     contentType: string,
                     body:        string,
                     ): DockerDigestedJson =
  return layer.layerPutFileStream(
    contentType = contentType,
    fileStream  = newLoadedFileStringStream(body),
  )

proc layerPutJson*(layer:       DockerImage,
                   contentType: string,
                   data:        JsonNode,
                  ): DockerDigestedJson =
  return layer.layerPutString(
    contentType = contentType,
    body        = $data,
  )

proc layerDelete*(layer: DockerImage): bool =
  try:
    let (_, response) = layer.request(
      useCase           = RegistryUseCase.ReadWrite,
      httpMethod        = HttpDelete,
      path              = "/blobs/" & layer.imageRef,
      acceptStatusCodes = @[200..299, 404..405],
    )
    if response.code() == Http405:
      warn("docker: registry does not support blob deletion for " & $layer)
      return false
    return true
  except:
    dumpExOnDebug()
    return false

proc manifestPut*(image:       DockerImage,
                  contentType: string,
                  data:        JsonNode,
                  byTag        = false,
                  ): DockerDigestedJson =
  let
    body   = $data
    digest = body.sha256Hex()
    image  = image.withDigest(body.sha256Hex())
  try:
    result = image.manifestHead(
      useCase = RegistryUseCase.ReadWrite,
    )
    trace("docker: manifest already exists. nothing to upload")
  except RegistryResponseError:
    trace("docker: manifest doesnt exist. uploading " & $image)
    let (_, response) = image.request(
      useCase     = RegistryUseCase.ReadWrite,
      httpMethod  = HttpPut,
      contentType = contentType,
      body        = body,
      path        = "/manifests/" & (
        if byTag:
          image.tag
        else:
          image.imageRef
      ),
    )
    checkReferrersSupport(image, response)
    return newDockerDigestedJson(
      data      = data,
      digest    = validateDigest(response.headers.mustGet("Docker-Content-Digest", "registry PUT response missing Docker-Content-Digest header")),
      mediaType = contentType,
      size      = len(body),
    )

proc originKey(url: Uri): string =
  let value = uriOrigin(url)
  return value.scheme & "://" & value.hostname & ":" & value.port

proc resolveReferrerNextLink*(current: Uri, link: string): Option[Uri] =
  return resolveSameOrigin(current, link)

proc descriptorDigest(item: JsonNode): string =
  if item == nil or item.kind != JObject:
    return ""
  return item{"digest"}.getStr()

proc referrersGet*(image:        DockerImage,
                   artifactType = "",
                  ): DockerDigestedJson =
  ## Returns the OCI referrers index for image, or nil if the registry
  ## does not support the referrers API.  image.digest must be set.
  ## artifactType filters the result to referrers with a matching artifactType.
  ## Under strictReferrerLinks, same-origin `Link: rel="next"` pages are
  ## merged and malformed pages raise RegistryReferrersError.
  var
    path = (
      if artifactType != "":
        "/referrers/" & image.imageRef & "?artifactType=" &
          encodeUrl(artifactType, usePlus = false)
      else:
        "/referrers/" & image.imageRef
    )
    nextUrl = initUri()
    all     = newJArray()
    pages   = 0
    seenPages = initHashSet[string]()
    seenDigests = initHashSet[string]()
    access = currentRegistryAccess
  try:
    while true:
      inc pages
      let (_, response) = image.request(
        useCase           = RegistryUseCase.ReadOnly,
        httpMethod        = HttpGet,
        path              = path,
        url               = nextUrl,
        accept            = "application/vnd.oci.image.index.v1+json",
        acceptStatusCodes = @[200..299, 404..404],
        requireSameOrigin = access.strictReferrerLinks,
      )
      if not response.code().is2xx():
        if pages == 1:
          return nil
        raise newException(RegistryReferrersError, "referrer pagination is incomplete")
      if not access.strictReferrerLinks:
        return newDockerDigestedJson(
          data      = response.body(),
          digest    = response.body().sha256Hex(),
          mediaType = "application/vnd.oci.image.index.v1+json",
        )
      let parsed = parseJson(response.body())
      if access.strictReferrerLinks:
        let mediaType = parsed{"mediaType"}.getStr()
        if mediaType != "" and mediaType != "application/vnd.oci.image.index.v1+json":
          raise newException(RegistryReferrersError, "referrer index has the wrong media type")
      for item in parsed{"manifests"}.getElems():
        if access.strictReferrerLinks:
          let digest = descriptorDigest(item)
          if digest == "" or digest in seenDigests:
            continue
          seenDigests.incl(digest)
        all.add(item)
      let pageKey = originKey(access.lastRequestUri) & access.lastRequestUri.path &
                    "?" & access.lastRequestUri.query
      if pageKey in seenPages:
        raise newException(RegistryReferrersError, "referrer pagination repeated a page")
      seenPages.incl(pageKey)
      let link =
        if response.headers.hasKey("Link"):
          nextLink(response.headers["Link"])
        else:
          ""
      if link == "":
        break
      if pages >= 32:
        raise newException(RegistryReferrersError, "referrer pagination is incomplete")
      let resolved = resolveReferrerNextLink(access.lastRequestUri, link)
      if resolved.isNone():
        raise newException(RegistryReferrersError, "referrer pagination left the registry origin")
      nextUrl = resolved.get()
      path = ""
    let merged = %*{
      "schemaVersion": 2,
      "mediaType":     "application/vnd.oci.image.index.v1+json",
      "manifests":     all,
    }
    let body = $merged
    return newDockerDigestedJson(
      data      = merged,
      digest    = body.sha256Hex(),
      mediaType = "application/vnd.oci.image.index.v1+json",
    )
  except RegistryTimeoutError:
    raise
  except:
    dumpExOnDebug()
    if access.strictReferrerLinks:
      raise
    return nil

proc supportsReferrers*(image: DockerImage): bool =
  let
    access = currentRegistryAccess
    key    = image.withBare().asRepoRef()
  if key in access.referrersCache:
    return access.referrersCache[key]
  result = referrersGet(image) != nil
  access.referrersCache[key] = result
  if result:
    trace("attestation: registry supports OCI referrers API for " & $image)
  else:
    trace("attestation: registry does not support OCI referrers API for " & $image)

proc toChalkDict(self: RegistryConfig): ChalkDict =
  result = ChalkDict()
  # double // to avoid docker hub normalization with library/ prefix
  let image: DockerImage = (self.registry & "//", "", "")
  result["url"]                  = pack($image.uri(
    scheme  = self.scheme,
    prefix  = self.prefix,
    project = self.project,
    path    = "/",
  ))
  result["source"]               = pack(self.source)
  result["scheme"]               = pack(self.scheme.split(':')[0])
  result["http"]                 = pack(self.scheme == "http://")
  result["secure"]               = pack(self.verifyMode == CVerifyPeer)
  result["insecure"]             = pack(self.verifyMode == CVerifyNone)
  result["auth"]                 = pack(len(self.auth) > 0)
  result["www_auth"]             = pack(self.usesWwwAuth())
  if self.scheme == "https://":
    if self.certPath != "":
      result["pinned_cert_path"] = pack(self.certPath)
    if self.pinnedCert != "":
      result["pinned_cert"]      = pack(tryToLoadFile(self.pinnedCert))
  if self.mirroring != "":
    result["mirroring"]          = pack(self.mirroring)

proc getUsedRegistryConfigs*(): ChalkDict =
  result = ChalkDict()
  for _, config in currentRegistryAccess.configByRegistry.pairs():
    result[config.registry] = pack(config.toChalkDict())
