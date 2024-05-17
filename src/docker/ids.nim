##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[sets, sequtils, uri]
import ".."/[config, util]

const hashHeader = "sha256:"

proc extractDockerHash*(value: string): string =
  # this function is also used to process container ids
  # which can start with / hence the strip
  return value.removePrefix(hashHeader).strip(chars = {'/'})

proc extractDockerHash*(value: Box): Box =
  return pack(extractDockerHash(unpack[string](value)))

# ----------------------------------------------------------------------------

proc `$`*(self: DockerPlatform): string =
  return self.os & "/" & self.architecture

proc `$`*(items: seq[DockerPlatform]): seq[string] =
  result = @[]
  for i in items:
    result.add($i)

proc `==`*(self, other: DockerPlatform): bool =
  if isNil(self) or isNil(other):
    return isNil(self) == isNil(other)
  return $self == $other

proc isKnown*(self: DockerPlatform): bool =
  return (
    not isNil(self) and
    self.os != "" and
    self.os != "unknown" and
    self.architecture != "" and
    self.architecture != "unknown"
  )

proc parseDockerPlatform*(platform: string): DockerPlatform =
  let items = platform.split('/', maxsplit = 1)
  if len(items) != 2:
    raise newException(ValueError, "Invalid docker platform: " & platform)
  return DockerPlatform(os: items[0], architecture: items[1])

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

proc parseDigest*(digest: string): DockerImage =
  return ("", "", digest.extractDockerHash())

proc parseImage*(name: string, defaultTag = "latest"): DockerImage =
  # parseUri requires some scheme to parse url correctly so we add dummy https
  # parsed uri will allow us to figure out if tag contains version
  # (note that tag can be full registry path which can include
  # port in the hostname)
  if name.startsWith(hashHeader):
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

proc parseImages*(names: seq[string]): seq[DockerImage] =
  result = @[]
  for name in names:
    if name != "":
      result.add(parseImage(name))

proc withDigest*(self: DockerImage, digest: string): DockerImage =
  return (self.repo, self.tag, digest.extractDockerHash())

proc withDigest*(items: seq[DockerImage], digest: string): seq[DockerImage] =
  result = @[]
  for i in items:
    result.add(i.withDigest(digest))

# below are various rendering variants as in different cases
# different form is required
# for example to interact with the registry tag should be omitted - <repo>@sha256:<digest>
# locally for docker inspect - <repo>:<tag>

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
    result &= "@" & hashHeader & self.digest

proc asRepoRef*(self: DockerImage): string =
  ## render image as precisely as possible
  ## however dont render both tag and digest at the same time
  if self.digest == "":
    result = self.asRepoTag()
  else:
    if self.repo == "":
      result = hashHeader & self.digest
    else:
      result = self.asRepoDigest()

proc `$`*(self: DockerImage): string =
  ## render all available information about image
  if self.repo != "":
    result = self.asRepoTag()
    if self.digest != "":
      result &= "@" & hashHeader & self.digest
  elif self.digest != "":
    result = hashHeader & self.digest
  else:
    raise newException(
      ValueError,
      "docker image is empty to be represented correctly"
    )

proc asRepoTag*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
    result.add(i.asRepoTag())

proc asRepoDigest*(items: seq[DockerImage]): seq[string] =
  result = @[]
  for i in items:
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
  return items.asRepoDigest().toSet().toSeq().parseImages()

proc getImageName*(self: ChalkObj): string =
  if len(self.images) > 0:
    return $(self.images[0])
  return self.name

# ----------------------------------------------------------------------------

proc extractDockerHashList*(value: seq[string]): seq[string] =
  for item in value:
    result.add(item.extractDockerHash())

proc extractDockerHashMap*(value: seq[string]): OrderedTableRef[string, string] =
  result = newOrderedTable[string, string]()
  for image in parseImages(value).uniq():
    if image.digest == "":
      raise newException(
        ValueError,
        "Invalid docker repo name. Expecting <repo>@sha256:<digest> but got: " & $image
      )
    # specifically omitting tag as digest is more precise to reference
    # something from the registry
    result[image.repo] = image.digest

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
