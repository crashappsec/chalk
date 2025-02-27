##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[net, sets, uri]
import ".."/[config, util]

const
  DEFAULT_REGISTRY = "registry-1.docker.io"
  DOCKER_HUB       = "https://hub.docker.com"
  LIBRARY          = "library/"
  HASH_HEADER      = "sha256:"
  REGISTRY_MAPPING = {
    "docker.io":       DEFAULT_REGISTRY,
    "index.docker.io": DEFAULT_REGISTRY,
  }.toTable()

proc normalizeRegistry*(self: string): string =
  return REGISTRY_MAPPING.getOrDefault(self, self)

proc registryAliases*(self: string): HashSet[string] =
  result.incl(self)
  for k, v in REGISTRY_MAPPING:
    if k == self or v == self:
      result.incl(k)
      result.incl(v)

proc registry*(uri: Uri): string =
  var registry = uri.hostname
  if uri.port != "":
    registry &= ":" & uri.port
  return registry.normalizeRegistry()

proc extractDockerHash*(value: string): string =
  # this function is also used to process container ids
  # which can start with / hence the strip
  return value.removePrefix(HASH_HEADER).strip(chars = {'/'})

proc extractDockerHash*(value: Box): Box =
  return pack(extractDockerHash(unpack[string](value)))

# ----------------------------------------------------------------------------

proc normalize*(self: DockerPlatform): DockerPlatform =
  # https://github.com/containerd/containerd/blob/83031836b2cf55637d7abf847b17134c51b38e53/platforms/platforms.go
  const
    osMap = {
      "macos":          "darwin",
    }.toTable()
    archMap = {
      "aarch64":        "arm64",
      "i386":           "386",
      "x86_64":         "amd64",
      "x86-64":         "amd64",
    }.toTable()
    archToVariantMap = {
      "armel":         ("arm", "v6"),
      "armhf":         ("arm", "v7"),
    }.toTable()
    # https://github.com/containerd/containerd/blob/83031836b2cf55637d7abf847b17134c51b38e53/platforms/database.go#L76-L109
    archWithVariantMap = {
      ("arm",   ""):   ("arm",   "v7"),
      ("arm64", "v8"): ("arm64", ""),
      ("amd64", "v1"): ("amd64", ""),
    }.toTable()
  var
    os           = osMap.getOrDefault(self.os, self.os)
    architecture = archMap.getOrDefault(self.architecture, self.architecture)
    variant      = self.variant
  (architecture, variant) = archToVariantMap.getOrDefault(
    architecture,
    (architecture, variant),
  )
  (architecture, variant) = archWithVariantMap.getOrDefault(
    (architecture, variant),
    (architecture, variant),
  )
  return DockerPlatform(
    os:           os,
    architecture: architecture,
    variant:      variant,
  )

proc normalize*(items: seq[DockerPlatform]): seq[DockerPlatform] =
  result = @[]
  for i in items:
    result.add(i.normalize())

proc `$`*(self: DockerPlatform): string =
  result = self.os & "/" & self.architecture
  if self.variant != "":
    result &= "/" & self.variant

proc `$`*(items: seq[DockerPlatform]): seq[string] =
  result = @[]
  for i in items:
    result.add($i)

proc `==`*(self, other: DockerPlatform): bool =
  if isNil(self) or isNil(other):
    return isNil(self) == isNil(other)
  return $self.normalize() == $other.normalize()

proc isKnown*(self: DockerPlatform): bool =
  return (
    not isNil(self) and
    self.os != "" and
    self.os != "unknown" and
    self.architecture != "" and
    self.architecture != "unknown"
  )

proc parseDockerPlatform*(platform: string): DockerPlatform =
  let parts = platform.toLower().split('/', maxsplit = 2)
  case len(parts)
  of 1:
    if parts[0] in ["linux", "macos", "darwin"]:
      return DockerPlatform(
        os:           parts[0],
        architecture: hostCPU,
      )
    else:
      return DockerPlatform(
        os:           hostOs,
        architecture: parts[0],
      )
  of 2:
    return DockerPlatform(
      os:           parts[0],
      architecture: parts[1],
    )
  of 3:
    return DockerPlatform(
      os:           parts[0],
      architecture: parts[1],
      variant:      parts[2],
    )
  else:
    raise newException(ValueError, "Invalid docker platform: " & platform)

proc contains*[T](self: TableRef[DockerPlatform, T], key: DockerPlatform): bool =
  for k, _ in self:
    if k == key:
      return true
  return false

proc `[]`*[T](self: TableRef[DockerPlatform, T], key: DockerPlatform): T =
  for k, v in self:
    if k == key:
      return v
  raise newException(KeyError, $key & " platform not found")

# ----------------------------------------------------------------------------

proc parseImage*(name: string, defaultTag = "latest"): DockerImage =
  # parseUri requires some scheme to parse url correctly so we add dummy https
  # parsed uri will allow us to figure out if tag contains version
  # (note that tag can be full registry path which can include
  # port in the hostname)
  if name.startsWith(HASH_HEADER):
    return ("", "", name.extractDockerHash())

  let (image, rawDigest) = name.splitBy("@")
  let digest             = rawDigest.extractDockerHash()

  # image has a path component and therefore can be parsed as uri
  # it can be either something like:
  # * foo/bar:tag
  # * registry/foo:tag
  # * registry:1234/foo:tag
  # note that ":" can be both for the port and tag
  # so we need to split it wisely
  if '/' in image:
    let uri = parseUri("https://" & image)

    # tag is present
    if ':' in uri.path:
      let (repo, tag) = image.rSplitBy(":")
      return (repo, tag, digest)

    # there is no tag
    else:
      return (image, defaultTag, digest)

  # image is regular foo[:tag] format
  else:
    let (repo, tag) = image.splitBy(":", defaultTag)
    return (repo, tag, digest)

proc parseImages*(names: seq[string], defaultTag = "latest"): seq[DockerImage] =
  result = @[]
  for name in names:
    if name != "":
      result.add(parseImage(name, defaultTag = defaultTag))

proc withTag*(self: DockerImage, tag: string): DockerImage =
  if tag == "":
    return self
  return (self.repo, tag, self.digest)

proc isPinned*(self: DockerImage): bool =
  return self.digest != "" or self.repo == "scratch"

proc withDigest*(self: DockerImage, digest: string): DockerImage =
  return (self.repo, self.tag, digest.extractDockerHash())

proc withDigest*(items: seq[DockerImage], digest: string): seq[DockerImage] =
  result = @[]
  for i in items:
    result.add(i.withDigest(digest))

proc isFullyQualified(self: DockerImage): bool =
  ## determine if the docker image is a fully qualified image name (contains domain)
  ## and all interactions should go there or registry is implicitly
  ## docker hub when not fully qualified (e.g. docker pull alpine).
  ##
  ## To determine fully qualified docker checks:
  ## * if its localhost
  ## * presence of `.` or `:` (port) in the potential registy domain
  ## * if its uppercase as repo name cannot have uppercase chars
  ##
  ## Rverything else is defaulted to docker hub even if its valid and resolvable domain
  ## like `registry/test` even if `registry` is a valid resolvable address locally
  ## (e.g. via `/etc/hosts` file)
  ## https://github.com/docker/cli/blob/826fc32e82e23bb5f80e85d8777427c5f0c24b4d/cli/command/image/pull.go#L58C36-L58C56
  ## https://github.com/distribution/reference/blob/8c942b0459dfdcc5b6685581dd0a5a470f615bff/normalize.go#L143-L191
  if self.repo == "scratch":
    return true
  let parts = self.repo.split('/', maxsplit = 1)
  # there is no parts in the name so like "nginx"
  # so it cant be fully qualified name
  if len(parts) == 1:
    return false
  let maybeRegistry = parts[0]
  return (
    maybeRegistry.toLower() == "localhost" or
    {':', '.'} in maybeRegistry or
    maybeRegistry.toLower() != maybeRegistry
  )

proc qualify(self: DockerImage): DockerImage =
  ## fully qualify image name with the full registry domain
  ## note qualified name does not specify any scheme like http or https
  ## it simply specifies complete image reference in the registry
  if self.isFullyQualified():
    return self
  result = (
    DEFAULT_REGISTRY & "/" & self.repo,
    self.tag,
    self.digest,
  )

proc normalize(self: DockerImage): DockerImage =
  ## normalize qualified registry domain
  ## normalization maps some hardcoded registry domains
  ## to their standard API domains
  # https://github.com/docker/cli/issues/3793#issuecomment-1269051403
  if self.repo == "scratch":
    return self
  let
    qualified        = self.qualify()
    (registry, path) = qualified.repo.splitBy("/")
    fullRegistry     = registry.normalizeRegistry()
    fullPath         =
      # library/ is only relevant to docker hub
      # all external registries are allowed top-level repos
      if fullRegistry != DEFAULT_REGISTRY or '/' in path:
        path
      else:
        LIBRARY & path
  result = (
    fullRegistry & "/" & fullPath,
    self.tag,
    self.digest,
  )

proc withRegistry*(self: DockerImage, registry: string): DockerImage =
  if registry == "":
    return self
  # parseUri doesnt parse uri without any scheme
  let
    normalized = self.normalize()
    parsed     = parseUri("https://" & registry)
  var uri      = parseUri("https://" & normalized.repo)
  uri.hostname = parsed.hostname
  uri.port     = parsed.port
  let repo = ($uri).removePrefix("https://")
  result = (
    repo,
    self.tag,
    self.digest,
  )

proc registry*(self: DockerImage): string =
  let parts = self.normalize().repo.split('/', maxsplit = 1)
  if len(parts) == 1:
    return ""
  return parts[0]

proc domain*(self: DockerImage): string =
  return self.registry.split(':', maxsplit = 1)[0]

proc name*(self: DockerImage): string =
  return self.normalize().repo.split('/', maxsplit = 1)[^1]

proc isDockerHub*(self: DockerImage): bool =
  return self.normalize().registry == DEFAULT_REGISTRY

proc uri*(self:   DockerImage,
          scheme  = "",
          path    = "",
          prefix  = "",
          project = "",
          ): Uri =
  ## generate working URI for the registry API
  ## note this only supports v2 registries hence hardcodes v2 suffix
  ## also this doesnt account for any insecure registry configs
  let normalized = self.normalize()
  var uri        = parseUri("https://" & normalized.repo)
  let uriPath    = uri.path
  uri.path = (
    prefix.removeSuffix('/') &
    "/v2" &
    project.removeSuffix('/') &
    uriPath.removeSuffix('/') &
    path
  )
  if scheme == "":
    if uri.hostname in @["localhost", $IPv4_loopback(), $IPv6_loopback()]:
      uri.scheme = "http"
    else:
      uri.scheme = "https"
  else:
    uri.scheme = scheme.split(":")[0]
  return uri

proc url*(self: DockerImage): string =
  ## generate user-accessible URL for the registry
  ## currently only supports:
  ## * Docker Hub
  if self.isDockerHub():
    let
      name = self.name
      path =
        if name.startsWith(LIBRARY):
          "/_/" & name.split('/', maxsplit = 1)[^1]
        else:
          "/r/" & name
    return DOCKER_HUB & path
  return ""

# below are various rendering variants as in different cases
# different form is required
# for example to interact with the registry tag should be omitted - <repo>@sha256:<digest>
# locally for docker inspect - <repo>:<tag>

proc imageRef*(self: DockerImage): string =
  if self.digest != "":
    result = HASH_HEADER & self.digest
  elif self.tag != "":
    result = self.tag
  else:
    result = "latest"

proc asRepoTag*(self: DockerImage): string =
  ## render image as repo+tag
  ## this is a human-readable representation of an image name
  if self.repo == "":
    raise newException(
      ValueError,
      "repo is missing to render with repo tag"
    )
  result = self.repo
  if self.tag != "":
    result &= ":" & self.tag

proc asRepoDigest*(self: DockerImage): string =
  ## render image as repo+digest
  ## this is how things can be queried from registry for example
  ## as including a tag can make the request ambiguous
  if self.repo == "":
    raise newException(
      ValueError,
      "repo is missing to render with repo tag"
    )
  result = self.repo
  if self.digest != "":
    result &= "@" & HASH_HEADER & self.digest

proc asRepoRef*(self: DockerImage): string =
  ## render image as precisely as possible
  ## however dont render both tag and digest at the same time
  if self.digest == "":
    result = self.asRepoTag()
  else:
    if self.repo == "":
      result = HASH_HEADER & self.digest
    else:
      result = self.asRepoDigest()

proc `$`*(self: DockerImage): string =
  ## render all available information about image
  if self.repo != "":
    result = self.asRepoTag()
    if self.digest != "":
      result &= "@" & HASH_HEADER & self.digest
  elif self.digest != "":
    result = HASH_HEADER & self.digest
  else:
    raise newException(
      ValueError,
      "docker image is empty to be represented correctly"
    )

proc exists*(self: DockerImage): bool =
  return self != ("", "", "")

proc asRepoTag*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
    if i.tag != "":
      result.add(i.asRepoTag())

proc asRepoDigest*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
    if i.digest != "":
      result.add(i.asRepoDigest())

proc asRepoRef*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
    result.add(i.asRepoRef())

proc `$`*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
    result.add($i)

proc uniq*(items: seq[DockerImage]): seq[DockerImage] =
  var unique = initHashSet[string]()
  result = @[]
  for i in items:
    let key = i.asRepoRef()
    if key in unique:
      continue
    unique.incl(key)
    result.add(i)

# ----------------------------------------------------------------------------

iterator manifests*(self: DockerImageRepo): DockerImage =
  for i in self.digests:
    yield (self.repo, "", i)

iterator listManifests*(self: DockerImageRepo): DockerImage =
  for i in self.listDigests:
    yield (self.repo, "", i)

iterator tagImages*(self: DockerImageRepo): DockerImage =
  for i in self.tags:
    yield (self.repo, i, "")

iterator manifests*(items: OrderedTableRef[string, DockerImageRepo]): DockerImage =
  for _, repo in items:
    for i in repo.manifests:
      yield i

iterator listManifests*(items: OrderedTableRef[string, DockerImageRepo]): DockerImage =
  for _, repo in items:
    for i in repo.listManifests:
      yield i

proc `$`*(self: DockerImageRepo): string =
  for i in self.listManifests:
    return $i
  for i in self.manifests:
    return $i
  raise newException(ValueError, "No digests to reference")

proc `+`*(a: DockerImageRepo, b: DockerImageRepo): DockerImageRepo =
  if b == nil:
    return a
  if a == nil:
    return b
  if a.repo != b.repo:
    raise newException(ValueError, "cannot merge image repos for different repos")
  return DockerImageRepo(
    repo       : b.repo,
    digests    : b.digests     + a.digests,
    listDigests: b.listDigests + a.listDigests,
    tags       : b.tags        + a.tags,
  )

# ----------------------------------------------------------------------------

proc getImageName*(self: ChalkObj): string =
  for _, repo in self.repos:
    return $repo
  return self.name

# ----------------------------------------------------------------------------

proc asImage*(self: DockerManifest): DockerImage =
  return self.name.withDigest(self.digest)

proc asImageRepo*(self: DockerManifest, tag = ""): DockerImageRepo =
  if self.kind != image:
    raise newException(ValueError, "Only image manifest can be image repo referenced")
  var tags = newSeq[string]()
  if self.name.tag != "":
    tags.add(self.name.tag)
  if tag != "":
    tags.add(tag)
  return DockerImageRepo(
    repo:    self.name.repo,
    digests: @[self.digest.extractDockerHash()].toOrderedSet(),
    listDigests: (
      if self.list != nil:
        @[self.list.digest.extractDockerHash()]
      else:
        @[]
    ).toOrderedSet(),
    tags: tags.toOrderedSet(),
  )

# ----------------------------------------------------------------------------

proc extractDockerHashList*(value: seq[string]): seq[string] =
  for item in value:
    result.add(item.extractDockerHash())

# ----------------------------------------------------------------------------

proc chooseNewTag*(): string =
  let
    randInt = secureRand[uint]()
    hexVal  = toHex(randInt and 0xffffffffffff'u).toLowerAscii()
  return "chalk-" & hexVal & ":latest"

proc dockerGenerateChalkId*(): string =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in b: preRes.add(ch)
  return preRes.idFormat()
