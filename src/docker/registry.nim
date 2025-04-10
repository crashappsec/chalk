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

import std/[net, uri, httpclient, nativesockets, sets]
import pkg/nimutils/net
import pkg/[zippy/tarballs]
import ".."/[config, ip, util, www_authenticate]
import "."/[exe, json, ids, nodes]

type
  RegistryResponseError* = object of ValueError

  # depending on use, mirror is allowed to be used or not
  # for read-only docker can consult mirrors
  # whereas if it indents to write to the registry,
  # it only talks to the upstream registry
  RegistryUseCase* = enum
    ReadWrite
    ReadOnly # allows use of mirrors

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
    auth*:        HttpHeaders
    wwwAuth*:     TableRef[string, HttpHeaders]
    fallthrough*: bool # whether to fallthrough to next config on http errors

const
  TIMEOUT = 3000 # sec
  CONTENT_TYPE_MAPPING = {
    "application/vnd.docker.distribution.manifest.list.v2+json": DockerManifestType.list,
    "application/vnd.docker.distribution.manifest.v2+json": DockerManifestType.image,
    "application/vnd.docker.container.image.v1+json": DockerManifestType.config,
    "application/vnd.docker.image.rootfs.diff.tar.gzip": DockerManifestType.layer,

    "application/vnd.oci.image.index.v1+json": DockerManifestType.list,
    "application/vnd.oci.image.manifest.v1+json": DockerManifestType.image,
    "application/vnd.oci.image.config.v1+json": DockerManifestType.config,
  }.toTable()

iterator uses(useCase: RegistryUseCase): RegistryUseCase =
  ## which uses lookups are applicable for the registry use
  ## ReadOnly use can only be used for reads
  ## however ReadWrite use can be used for both
  yield useCase
  if useCase == RegistryUseCase.ReadWrite:
    yield RegistryUseCase.ReadOnly

proc usesWwwAuth(self: RegistryConfig): bool =
  for _, auth in self.wwwAuth.pairs():
    if len(auth) > 0:
      return true
  return false

proc withBasicAuth(self: RegistryConfig, token: string): RegistryConfig =
  if token != "":
    self.auth = newHttpHeaders(@[
      ("Authorization", "Basic " & token),
    ])
  else:
    self.auth = newHttpHeaders()
  self.wwwAuth = newTable[string, HttpHeaders]()
  return self

iterator iterDaemonSpecificRegistryConfigs(self:         DockerImage,
                                           withHttp    = true,
                                           prefix      = "",
                                           mirroring   = "",
                                           fallthrough = false): RegistryConfig =
  yield RegistryConfig(
    source:      "daemon",
    scheme:      "https://",
    registry:    self.registry,
    prefix:      prefix,
    verifyMode:  CVerifyPeer,
    mirroring:   mirroring,
    fallthrough: fallthrough,
  )

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
    yield RegistryConfig(
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
    )

  for i in getDockerInfoSubList("insecure registries:"):
    if self.registry == i or self.domain == i:
      trace("docker: " & i & " is configured as an insecure registry in docker daemon")
      trace("docker: " & self.registry & " will attempt TLS without verifying server cert")
      yield RegistryConfig(
        source:      "daemon",
        scheme:      "https://",
        registry:    self.registry,
        prefix:      prefix,
        verifyMode:  CVerifyNone,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      )
      if withHttp:
        yield RegistryConfig(
          source:      "daemon",
          scheme:      "http://",
          registry:    self.registry,
          prefix:      prefix,
          verifyMode:  CVerifyNone,
          mirroring:   mirroring,
          fallthrough: fallthrough,
        )
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
        if selfIp.family != ip.family:
          continue
        if selfIp in ipRange:
          trace("docker: " & self.domain & " (" & $selfIp & ") is an insecure registry via IP address match for " & i)
          trace("docker: " & self.registry & " will attempt TLS without verifying server cert")
          yield RegistryConfig(
            source:      "daemon",
            scheme:      "https://",
            registry:    self.registry,
            prefix:      prefix,
            verifyMode:  CVerifyNone,
            mirroring:   mirroring,
            fallthrough: fallthrough,
          )
          if withHttp:
            yield RegistryConfig(
              source:      "daemon",
              scheme:      "http://",
              registry:    self.registry,
              prefix:      prefix,
              verifyMode:  CVerifyNone,
              mirroring:   mirroring,
              fallthrough: fallthrough,
            )
      except:
        continue

iterator iterDaemonRegistryConfigs(self: DockerImage, useCase: RegistryUseCase): RegistryConfig =
  # docker daemon only suports docker hub mirror
  if useCase == RegistryUseCase.ReadOnly and self.isDockerHub():
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
        for i in mirrored.iterDaemonSpecificRegistryConfigs(
          withHttp    = false,
          prefix      = prefix,
          mirroring   = self.registry,
          fallthrough = true,
        ):
          yield i
      else:
        yield RegistryConfig(
          source:      "daemon",
          scheme:      "http://",
          registry:    registry,
          prefix:      prefix,
          verifyMode:  CVerifyNone,
          mirroring:   self.registry,
          fallthrough: true,
        )

  for i in self.iterDaemonSpecificRegistryConfigs():
    yield i

proc findRegistry(self: JsonNode, registry: string): JsonNode =
  if "registry" notin self:
    return nil
  for r in registry.registryAliases():
    if r in self{"registry"}:
      return self["registry"][r]
  return nil

iterator iterBuildxSpecificRegistryConfigs(self:         DockerImage,
                                           node:         string,
                                           config:       JsonNode,
                                           mirroring   = "",
                                           project     = "",
                                           fallthrough = false): RegistryConfig =
  let registry = config.findRegistry(self.registry)
  if registry != nil:
    let
      http     = registry{"http"}.getBool()
      insecure = registry{"insecure"}.getBool()
      certs    = registry{"ca"}
    if not insecure and not http:
      yield RegistryConfig(
        source:      "buildx",
        scheme:      "https://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyPeer,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      )
    if certs != nil and certs.kind == JArray:
      for cert in certs:
        let path = cert.getStr()
        try:
          let data = dockerInvocation.readBuilderNodeFile(node, path)
          trace("docker: found CA certificate for " & self.registry & " at " & path & " in buildx node " & node)
          yield RegistryConfig(
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
          )
        except:
          trace("docker: cannot read buildx registry CA from " & path & " in buildx node " & node)
          continue
    if insecure:
      trace("docker: " & self.registry & " is configured as an insecure registry in docker buildx node " & node)
      yield RegistryConfig(
        source:      "buildx",
        scheme:      "https://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyNone,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      )
    if http:
      trace("docker: " & self.registry & " is configured as an http registry in docker buildx node " & node)
      yield RegistryConfig(
        source:      "buildx",
        scheme:      "http://",
        registry:    self.registry,
        project:     project,
        verifyMode:  CVerifyNone,
        mirroring:   mirroring,
        fallthrough: fallthrough,
      )

iterator iterBuildxRegistryConfigs(self: DockerImage, useCase: RegistryUseCase): RegistryConfig =
  if hasBuildX():
    if useCase == RegistryUseCase.ReadOnly:
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
              for i in mirrored.iterBuildxSpecificRegistryConfigs(
                node,
                config,
                project     = project,
                mirroring   = self.registry,
                fallthrough = true,
              ):
                yield i
            except:
              trace("docker: cannot inspect buildx mirror " & mirror & " config due to: " & getCurrentExceptionMsg())
              continue
        except:
          trace("docker: cannot inspect buildx mirror config due to: " & getCurrentExceptionMsg())
          continue

    # try most secure config just in case it works
    # to avoid parsing configs when use is readwrite
    yield RegistryConfig(
      source:      "buildx",
      scheme:      "https://",
      registry:    self.registry,
      verifyMode:  CVerifyPeer,
    )
    for node, config in dockerInvocation.iterBuilderNodesConfigs():
      try:
        for i in self.iterBuildxSpecificRegistryConfigs(node, config):
          yield i
      except:
        trace("docker: cannot inspect buildx config due to: " & getCurrentExceptionMsg())
        continue

proc getBasicAuth(self: DockerImage): string =
  try:
    let config = getDockerAuthConfig()
    result = config{"auths"}{self.registry}{"auth"}.getStr()
    if result != "":
      trace("docker: using basic auth creds from docker config for " & self.registry)
  except:
    trace("docker: invalid auth config: " & getCurrentExceptionMsg())
    return ""

var configByRegistry = initTable[(RegistryUseCase, string), RegistryConfig]()
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

  if (useCase, self.registry) in configByRegistry:
    cached = configByRegistry[(useCase, self.registry)]
    checkedConfigs.add(cached)
    yield cached

  # if the cached registry config is a mirror,
  # we need to provide a way to fallthrough to upstream registry
  if cached == nil or cached.fallthrough:
    # find basic auth from docker config file
    let token = self.getBasicAuth()

    let isBuildx = (
      dockerInvocation != nil and
      dockerInvocation.cmd == build and
      dockerInvocation.foundBuildx
    )
    template buildx() =
      for i in self.iterBuildxRegistryConfigs(useCase = useCase):
        if i notin checkedConfigs:
          let i = i.withBasicAuth(token)
          checkedConfigs.add(i)
          yield i
    # when running buildx, buildx nodes configs should take precedence
    # over daemon configs but we still scan both just in case
    if isBuildx:
      buildx()
    for i in self.iterDaemonRegistryConfigs(useCase = useCase):
      if i notin checkedConfigs:
        let i = i.withBasicAuth(token)
        checkedConfigs.add(i)
        yield i
    if not isBuildx:
      buildx()

var jsonCache = initTable[
  (DockerImage, HttpMethod, string, RegistryUseCase),
  (string, Response)
]()
proc request(self:       DockerImage,
             httpMethod: HttpMethod,
             path:       string,
             accept:     string,
             useCase =   RegistryUseCase.ReadOnly,
             ): (string, Response) =
  let cacheKey = (self, httpMethod, path, useCase)
  if cacheKey in jsonCache:
    return jsonCache[cacheKey]
  for config in self.getConfigs(useCase = useCase):
    let uri = self.withRegistry(config.registry).uri(
      scheme  = config.scheme,
      prefix  = config.prefix,
      project = config.project,
      path    = path,
    )
    var msg = $httpMethod & " " & $uri
    if uri.scheme == "https":
      msg &= " " & $config.verifyMode
      if config.certPath != "":
        msg &= "@" & config.certPath
    trace("docker: " & msg)
    var invalid = false
    try:
      try:
        let
          wwwAuth = config.wwwAuth.getOrDefault(self.repo, newHttpHeaders())
          (authHeaders, response) = authHeadersSafeRequest(
            uri,
            httpMethod,
            headers    = newHttpHeaders(
              @[("Accept", accept)],
            ).update(config.auth).update(wwwAuth),
            pinnedCert = config.pinnedCert,
            verifyMode = config.verifyMode,
            timeout    = TIMEOUT,
            retries    = 2,
            only2xx    = true,
          )
        config.wwwAuth[self.repo] = wwwAuth.update(authHeaders)
        for u in useCase.uses():
          configByRegistry[(u, self.registry)] = config
          jsonCache[(self, httpMethod, path, u)] = (msg, response)
        return (msg, response)
      except ValueError:
        # ValueError is only raised when only2xx fails
        # for non-mirror registry:
        # as we can talk to the registry, any errors from this point on
        # mean image doesnt exist in the registry or invalid config such as
        # invalid auth which we cant improve even if we attempt other configs
        # for mirror registry:
        # as mirror might be missing the image, on 404s docker reattempts
        # to fetch the image from upstream registry bypassing the mirror
        # hence we need to fallthrough to the next config
        invalid = not config.fallthrough
        raise
    except:
      if invalid:
        raise newException(RegistryResponseError, getCurrentExceptionMsg())
      else:
        trace("docker: ignoring error: " & getCurrentExceptionMsg())
  raise newException(ValueError, "could not find working registry configuration for " & $self)

proc manifestHead*(image:    DockerImage,
                   useCase = RegistryUseCase.ReadOnly,
                   ): DockerDigestedJson =
  let
    (msg, response) = image.request(
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
    contentType = response.headers["Content-Type"]
    digest      = response.headers["Docker-Content-Digest"]
  if contentType notin CONTENT_TYPE_MAPPING:
    # TODO do heuristics on response payload as there are bound to be new mime types
    raise newException(
      ValueError,
      "docker: " & msg & " returned unsupported registry content type: " & contentType
    )
  let kind = CONTENT_TYPE_MAPPING[contentType]
  return newDockerDigestedJson("{}", digest, contentType, kind)

proc manifestGet*(image:    DockerImage,
                  accept:   string,
                  useCase = RegistryUseCase.ReadOnly,
                  ): DockerDigestedJson =
  let
    kind          = CONTENT_TYPE_MAPPING[accept]
    (_, response) = image.request(
      useCase    = useCase,
      httpMethod = HttpGet,
      path       = "/manifests/" & image.imageRef,
      accept     = accept,
    )
  return newDockerDigestedJson(response.body(), image.imageRef, accept, kind)

proc layerGetString*(image:    DockerImage,
                     accept:   string,
                     useCase = RegistryUseCase.ReadOnly,
                     ): string =
  let
    (_, response) = image.request(
      useCase    = useCase,
      httpMethod = HttpGet,
      path       = "/blobs/" & image.imageRef,
      accept     = accept,
    )
  return response.body()

proc layerGetJson*(image:    DockerImage,
                   accept:   string,
                   useCase = RegistryUseCase.ReadOnly,
                   ): DigestedJson =
  return parseAndDigestJson(
    image.layerGetString(
      useCase = useCase,
      accept  = accept,
    ),
    digest = image.imageRef,
  )

proc layerGetFSFileString*(image:    DockerImage,
                           name:     string,
                           accept:   string,
                           useCase = RegistryUseCase.ReadOnly,
                           ): string =
  trace("docker: extracting " & name & " from layer " & $image)
  let
    response = image.layerGetString(
      useCase = useCase,
      accept  = accept,
    )
    tarPath = writeNewTempFile(response, suffix = name)
  let
    # extract needs non-existing path so doing one more joinPath
    untarPath = getNewTempDir().joinPath(image.digest)
    namePath  = untarPath.joinPath(name)
  extractAll(tarPath, untarPath)
  result = tryToLoadFile(namePath)

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
  for _, config in configByRegistry.pairs():
    result[config.registry] = pack(config.toChalkDict())
