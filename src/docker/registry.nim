##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Docker registry v2 wrapper
## https://docker-docs.uclv.cu/registry/spec/api/
## https://docker-docs.uclv.cu/registry/spec/manifest-v2-2/
## https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
## https://docs.docker.com/build/buildkit/toml-configuration/

import std/[net, uri, httpclient, nativesockets]
import pkg/nimutils/net
import ".."/[config, ip, util, www_authenticate]
import "."/[exe, json, ids]

type
  RegistryResponseError* = object of ValueError

  RegistryConfig = ref object
    scheme*:     string
    certPath*:   string
    pinnedCert*: string
    verifyMode*: SslCVerifyMode
    auth*:       HttpHeaders

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

proc withBasicAuth(self: RegistryConfig, token: string): RegistryConfig =
  if token != "":
    self.auth = newHttpHeaders(@[
      ("Authorization", "Basic " & token),
    ])
  else:
    self.auth = newHttpHeaders()
  return self

iterator iterDaemonRegistryConfigs(self: DockerImage): RegistryConfig =
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
      scheme:     "https://",
      verifyMode: CVerifyPeer,
      certPath:   path,
      pinnedCert: writeNewTempFile(
        cert,
        prefix = self.domain,
        suffix = ".crt",
      ),
    )

  template yieldInsecure() =
    trace("docker: " & self.registry & " will attempt TLS without verifying server cert")
    yield RegistryConfig(scheme: "https://", verifyMode: CVerifyNone)
    yield RegistryConfig(scheme: "http://", verifyMode: CVerifyNone)

  for i in getDockerInfoSubList("insecure registries:"):
    if self.registry == i or self.domain == i:
      trace("docker: " & i & " is configured as an insecure registry in docker daemon")
      yieldInsecure()
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
          yieldInsecure()
      except:
        continue

iterator iterBuildxRegistryConfigs(self: DockerImage): RegistryConfig =
  # TODO this should be compatible outside of build commands
  # where docker daemon takes precedence
  if hasBuildx():
    for node, config in dockerInvocation.iterBuilderNodesConfigs():
      if self.registry notin config{"registry"}:
        continue
      try:
        let
          registry = config["registry"][self.registry]
          http     = registry{"http"}{"value"}.getStr()
          insecure = registry{"insecure"}{"value"}.getStr()
          certs    = registry{"ca"}{"value"}
        if certs != nil and certs.kind == JArray:
          for cert in certs:
            let path = cert{"value"}.getStr()
            try:
              let data = dockerInvocation.readBuilderNodeFile(node, path)
              trace("docker: found CA certificate for " & self.registry & " at " & path & " in buildx node " & node)
              yield RegistryConfig(
                scheme:     "https://",
                verifyMode: CVerifyPeer,
                certPath:   path,
                pinnedCert: writeNewTempFile(
                  data,
                  prefix = self.domain,
                  suffix = ".crt",
                ),
              )
            except:
              trace("docker: cannot read buildx registry CA from " & path & " in buildx node " & node)
              continue
        if insecure == "true":
          trace("docker: " & self.registry & " is configured as an insecure registry in docker buildx node " & node)
          yield RegistryConfig(scheme: "https://", verifyMode: CVerifyNone)
        if http == "true":
          trace("docker: " & self.registry & " is configured as an http registry in docker buildx node " & node)
          yield RegistryConfig(scheme: "http://", verifyMode: CVerifyNone)
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

var configByRegistry = initTable[string, RegistryConfig]()
iterator getConfigs(self: DockerImage): RegistryConfig =
  ## get all plausible configs for iteracting with the registry
  ## note this is explicitly implemented as an iterator
  ## as getting specific config can be more expensive as it might
  ## need to get docker daemon/buildx configs/etc
  ## and iterators allow to make that lazy where if a config attempt
  ## fails, only then next config is fetched until a working config
  ## is found
  if self.registry in configByRegistry:
    yield configByRegistry[self.registry]

  else:
    # find basic auth from docker config file
    let token = self.getBasicAuth()

    # some configs could be duplicates such as if there are multiple buildx
    # nodex they might all have equivalent configs
    var checkedConfigs = newSeq[RegistryConfig]()

    # always attempt to talk to registry via https first
    # which will bypass parsing all daemon/buildx configs/etc
    # plus in most production flows this should be most common case
    trace("docker: attempting secure registry config for " & self.registry)
    let https = RegistryConfig(scheme: "https://", verifyMode: CVerifyPeer).withBasicAuth(token)
    checkedConfigs.add(https)
    yield https

    let isBuildx = (
      dockerInvocation != nil and
      dockerInvocation.cmd == build and
      dockerInvocation.foundBuildx
    )
    template buildx() =
      for i in self.iterBuildxRegistryConfigs():
        if i notin checkedConfigs:
          let i = i.withBasicAuth(token)
          checkedConfigs.add(i)
          yield i
    # when running buildx, buildx nodes configs should take precedence
    # over daemon configs but we still scan both just in case
    if isBuildx:
      buildx()
    for i in self.iterDaemonRegistryConfigs():
      if i notin checkedConfigs:
        let i = i.withBasicAuth(token)
        checkedConfigs.add(i)
        yield i
    if not isBuildx:
      buildx()

proc request(self: DockerImage,
             httpMethod: HttpMethod,
             path: string,
             accept: string): (string, Response) =
  for config in self.getConfigs():
    let uri = self.uri(scheme = config.scheme, path = path)
    var msg = $httpMethod & " " & $uri
    if uri.scheme == "https":
      msg &= " " & $config.verifyMode
      if config.certPath != "":
        msg &= "@" & config.certPath
    trace("docker: " & msg)
    var invalid = false
    try:
      let response = authSafeRequest(
        uri,
        httpMethod,
        headers    = newHttpHeaders(
          @[("Accept", accept)],
        ).update(config.auth),
        pinnedCert = config.pinnedCert,
        verifyMode = config.verifyMode,
        timeout    = TIMEOUT,
        retries    = 2,
      )
      # as we can talk to the registry, any errors from this point on
      # mean image doesnt exist in the registry or invalid config such as
      # invalid auth which we cant improve even if we attempt other configs
      invalid = true
      discard response.check(url = uri, only2xx = true)
      configByRegistry[self.registry] = config
      return (msg, response)
    except:
      if invalid:
        raise newException(RegistryResponseError, getCurrentExceptionMsg())
  quit(1) # TODO obviously remove but useful for testing
  raise newException(ValueError, "could not find working registry configuration for " & $self)

proc manifestHead*(image: DockerImage): DockerDigestedJson =
  let
    (msg, response) = image.request(
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

proc manifestGet*(image: DockerImage, accept: string): DockerDigestedJson =
  let
    kind          = CONTENT_TYPE_MAPPING[accept]
    (_, response) = image.request(
      httpMethod = HttpGet,
      path       = "/manifests/" & image.imageRef,
      accept     = accept,
    )
  return newDockerDigestedJson(response.body(), image.imageRef, accept, kind)

proc layerGet*(image: DockerImage, accept: string): DockerDigestedJson =
  let
    kind          = CONTENT_TYPE_MAPPING[accept]
    (_, response) = image.request(
      httpMethod = HttpGet,
      path       = "/blobs/" & image.imageRef,
      accept     = accept,
    )
  return newDockerDigestedJson(response.body(), image.imageRef, accept, kind)
