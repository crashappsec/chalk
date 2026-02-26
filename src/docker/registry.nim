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

import std/[
  nativesockets,
  net,
  strscans,
  uri,
]
import pkg/[
  nimutils/net,
  zippy/tarballs,
]
import ".."/[
  types,
  utils/files,
  utils/ip,
  utils/json,
  utils/http,
  utils/sets,
  utils/strings,
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
    auth*:        TableRef[string, string]                      # by namespace
    wwwAuth*:     TableRef[string, TableRef[bool, HttpHeaders]] # by repo, httpmethod in HEAD,GET
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

    "application/octet-stream": DockerManifestType.layer,
  }.toTable()
  MEGABYTE = 1 shl 20

iterator uses(useCase: RegistryUseCase): RegistryUseCase =
  ## which uses lookups are applicable for the registry use
  ## ReadOnly use can only be used for reads
  ## however ReadWrite use can be used for both
  yield useCase
  if useCase == RegistryUseCase.ReadWrite:
    yield RegistryUseCase.ReadOnly

proc usesWwwAuth(self: RegistryConfig): bool =
  for _, auth in self.wwwAuth.pairs():
    for _, httpMethod in auth.pairs():
      if len(httpMethod) > 0:
        return true
  return false

proc uri(self: RegistryConfig): Uri =
  return parseUri(self.scheme & self.registry)

proc withAuth(self: RegistryConfig): RegistryConfig =
  result       = self
  self.wwwAuth = newTable[string, TableRef[bool, HttpHeaders]]()
  self.auth    = newTable[string, string]()
  let
    uri        = self.uri().withPort()
    config     = getDockerAuthConfig()
  if config == nil:
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
    let isBuildx = (
      dockerInvocation != nil and
      dockerInvocation.cmd == build and
      dockerInvocation.foundBuildx
    )
    template buildx() =
      for i in self.iterBuildxRegistryConfigs(useCase = useCase):
        if i notin checkedConfigs:
          let i = i.withAuth()
          checkedConfigs.add(i)
          yield i
    # when running buildx, buildx nodes configs should take precedence
    # over daemon configs but we still scan both just in case
    if isBuildx:
      buildx()
    for i in self.iterDaemonRegistryConfigs(useCase = useCase):
      if i notin checkedConfigs:
        let i = i.withAuth()
        checkedConfigs.add(i)
        yield i
    if not isBuildx:
      buildx()

var jsonCache = initTable[
  (DockerImage, HttpMethod, string, RegistryUseCase),
  (string, Response)
]()
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
             acceptStatusCodes: openArray[Slice[int]] = @[200..299],
             ): (string, Response) =
  let cacheKey = (self, httpMethod, path, useCase)
  if cacheKey in jsonCache:
    return jsonCache[cacheKey]
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
    var invalid = false
    try:
      try:
        var headers = newHttpHeaders()
        if accept != "":
          headers["Accept"] = accept
        if body != "":
          if contentType != "":
            headers["Content-Type"] = contentType
          # only include content-range header not chunked uploads
          # e.g. ghcr doesnt accept content-range for monolithic uploads
          if range.a > 0 or range.b > 0 and range.b - range.a + 1 != size:
            var contentRange = "bytes " & $range.a & "-" & $range.b
            if size > 0:
              contentRange &= "/" & $size
            headers["Content-Range"] = contentRange
          headers["Content-Length"] = $len(body)
        for k, v in headers.pairs():
          msg &= " " & k & ":" & v
        trace("docker: " & msg)
        let
          isGet   = httpMethod in [HttpHead, HttpGet]
          wwwAuth = (
            config.wwwAuth
            .mgetOrPut(normalized.repo, newTable[bool, HttpHeaders]())
            .mgetOrPut(isGet,           newHttpHeaders())
          )
          (authHeaders, response) = authHeadersSafeRequest(
            uri,
            httpMethod,
            body              = body,
            headers           = headers.update(config.authHeadersFor(normalized)).update(wwwAuth),
            pinnedCert        = config.pinnedCert,
            verifyMode        = config.verifyMode,
            timeout           = TIMEOUT,
            retries           = 2,
            acceptStatusCodes = acceptStatusCodes,
          )
        config.wwwAuth[normalized.repo][isGet] = wwwAuth.update(authHeaders)
        var respMsg = "docker: " & $response.status
        for k, v in response.headers.pairs():
          if k notin ["authorization"]:
            respMsg &= " " & k & ":" & v
        trace(respMsg)
        for u in useCase.uses():
          configByRegistry[(u, self.registry)] = config
          if isGet:
            jsonCache[cacheKey] = (msg, response)
        return (msg, response)
      except ValueError:
        # ValueError is only raised when status code fails
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
      msg & " returned unsupported registry content type: " & contentType
    )
  return newDockerDigestedJson(
    data      = JsonNode(nil),
    digest    = digest,
    mediaType = contentType,
    kind      = CONTENT_TYPE_MAPPING[contentType],
    size      = parseInt(response.headers["Content-Length"]),
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
  return newDockerDigestedJson(
    data      = response.body(),
    digest    = image.imageRef,
    mediaType = accept,
    kind      = CONTENT_TYPE_MAPPING[accept],
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

proc layerPutStart(layer: DockerImage,
                  ): Uri =
  let (_, initResponse) = layer.request(
    useCase     = RegistryUseCase.ReadWrite,
    httpMethod  = HttpPost,
    path        = "/blobs/uploads/",
    contentType = "application/octet-stream",
  )
  try:
    result = parseUri(initResponse.headers["Location"])
  except:
    raise newException(
      ValueError,
      "could not determine layer upload url due to: " & getCurrentExceptionMsg()
    )
  if not result.path.startsWith("/"):
    raise newException(
      ValueError,
      "upload Location is expected to be absolute path. Got: " & result.path
    )

proc nextStartAt(response: Response, startAt: int, attempts: int, retries = 2): (int, int) =
  if not response.headers.hasKey("Range"):
    raise newException(
      ValueError,
      "could not upload layer as reponse doesnt have expected Range header"
    )
  let (validRange, _, rangeEnd) = response.headers["Range"].scanTuple("$i-$i")
  if not validRange:
    raise newException(
      ValueError,
      "could not upload as Range response header is not valid format <start>-<end>: " &
      response.headers["Range"]
    )
  let nextStartAt = rangeEnd + 1
  var attempts = attempts
  if nextStartAt == startAt:
    attempts += 1
  else:
    attempts = 1
  return (nextStartAt, attempts)

proc layerPutFileStream*(layer:       DockerImage,
                         contentType: string,
                         fileStream:  FileStringStream,
                         # fyi docker cli seems to upload as monolithic upload :shrug:
                         chunkSize    = 5 * MEGABYTE,
                        ): DockerDigestedJson =
  let
    layer = layer.withDigest(fileStream.sha256Hex())
    size  = len(fileStream)
  try:
    let (_, response) = layer.request(
      useCase     = RegistryUseCase.ReadWrite,
      httpMethod  = HttpHead,
      path        = "/blobs/" & layer.imageRef,
      accept      = contentType,
    )
    trace("docker: layer already exists. nothing to upload")
    return newDockerDigestedJson(
      data      = JsonNode(nil),
      digest    = layer.digest,
      mediaType = response.headers["Content-Type"],
      size      = parseInt(response.headers["Content-Length"]),
      kind      = DockerManifestType.layer,
    )
  except RegistryResponseError:
    trace("docker: layer doesnt exist. uploading " & $layer)
    var
      location   = layer.layerPutStart()
      startAt    = 0
      attempts   = 1
      httpMethod = HttpPatch
      response:    Response
    while startAt < size - 1:
      let
        endAt   = min(startAt + chunkSize, size) - 1
        isFinal = endAt == size - 1
      if isFinal:
        location   = location.withQueryPair("digest", layer.imageRef)
        httpMethod = HttpPut
      try:
        (_, response) = layer.request(
          useCase           = RegistryUseCase.ReadWrite,
          httpMethod        = httpMethod,
          url               = location,
          body              = fileStream[startAt..endAt],
          range             = startAt..endAt,
          size              = size,
          contentType       = "application/octet-stream",
          acceptStatusCodes = [200..299, 416..416],
        )
      except:
        raise newException(
          ValueError,
          "could not upload layer due to: " & getCurrentExceptionMsg()
        )
      if response.code() == Http416:
        trace("docker: chunk not fully uploaded: " & response.body())
        (startAt, attempts)   = response.nextStartAt(startAt, attempts)
        location              = parseUri(response.headers["Location"])
      else:
        if response.headers.hasKey("Range"):
          (startAt, attempts) = response.nextStartAt(startAt, attempts)
        else:
          (startAt, attempts) = (endAt + 1, 1)
        if response.headers.hasKey("Location"):
          location            = parseUri(response.headers["Location"])
      if attempts > 2:
        raise newException(
          ValueError,
          "could not upload layer as upload Range is not incrementing after " &
          $attempts & " attempts"
        )
    # https://docker-docs.uclv.cu/registry/spec/api/
    # > The Docker-Content-Digest header returns the canonical digest of the
    # > uploaded blob which may differ from the provided digest.
    return newDockerDigestedJson(
      data      = JsonNode(nil),
      digest    = response.headers["Docker-Content-Digest"],
      mediaType = contentType,
      kind      = DockerManifestType.layer,
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
    return newDockerDigestedJson(
      data      = data,
      digest    = response.headers["Docker-Content-Digest"],
      mediaType = contentType,
      kind      = CONTENT_TYPE_MAPPING[contentType],
      size      = len(body),
    )

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
