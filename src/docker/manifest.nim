##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for interacting with remote registry docker manifests

import std/[httpclient]
import ".."/[chalk_common, config, www_authenticate]
import "."/[exe]

type DigestedJson = ref object
  json:   JsonNode
  digest: string
  size:   int

proc `$`(self: DockerPlatform): string =
  return self.os & "/" & self.architecture

proc parseDockerPlatform(platform: string): DockerPlatform =
  let items = platform.split('/', maxsplit = 1)
  if len(items) != 2:
    raise newException(ValueError, "Invalid docker platform: " & platform)
  return (os: items[0], architecture: items[1])

proc parseAndDigestJson(data: string): DigestedJson =
  return DigestedJson(
    json:   parseJson(data),
    digest: "sha256:" & sha256(data).hex(),
    size:   len(data),
  )

proc findPlatformManifest(self: DockerManifest, platform: DockerPlatform): DockerManifest =
  if self.kind != DockerManifestType.list:
    raise newException(AssertionDefect, "can only find platform manifest from manifest list")
  for manifest in self.manifests:
    if manifest.platform == platform:
      return manifest
  raise newException(KeyError, "Could not find manifest for: " & $platform)

proc getCompressedSize(self: DockerManifest): int =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "compressed image size can only be computed on image manifest")
  result = 0
  for layer in self.layers:
    result += layer.size

proc requestManifestJson(image: string): DigestedJson =
  ## fetch raw json manifest via docker imagetools
  ## however if that fails withs 401 error, attept to manually
  ## fetch the manifest via the URL from the error message
  ## as the error could be due to www-authenticate challenge
  let msg = "docker: fetching manifest for " & image
  trace(msg)
  let
    output = runDockerGetEverything(@["buildx", "imagetools", "inspect", image, "--raw"])
    stdout = output.getStdout()
    stderr = output.getStderr()
    text   = stdout & stderr
  if output.getExit() == 0:
    try:
      return parseAndDigestJson(stdout)
    except:
      raise newException(ValueError, msg & " failed with: " & getCurrentExceptionMsg())
  # sample output:
  # ERROR: unexpected status from HEAD request to https://<registry>: 401 Unauthorized
  if "401 Unauthorized" notin stderr:
    raise newException(ValueError, msg & " failed with: " & text)
  if not ("http://" in stderr or "https://" in stderr):
    raise newException(ValueError, msg & " auth failed without an URL: " & text)
  var url = ""
  for word in stderr.split():
    if word.startsWith("http://") or word.startsWith("https://"):
      url = word.strip(leading = false, chars = {':'})
      break
  if url == "":
    raise newException(ValueError, msg & " failed to find auth challenge URL: " & text)
  trace(msg & " requires auth. fetching www-authenticate challenge from: " & url)
  let headChallenge = safeRequest(url, httpMethod = HttpHead)
  if headChallenge.code() != Http401:
    raise newException(ValueError, msg & " failed to get 401 for: " & url)
  if not headChallenge.headers.hasKey("www-authenticate"):
    raise newException(ValueError, msg & " www-authenticate header is not returned by: " & url)
  try:
    let
      wwwAuthenticate = headChallenge.headers["www-authenticate"]
      challenges      = parseAuthChallenges(wwwAuthenticate)
      headers         = challenges.elicitHeaders()
    trace(msg & " from URL: " & url)
    let response      = safeRequest(url, headers = headers)
    if not response.code().is2xx():
      raise newException(ValueError, msg & " manifest was not returned from URL: " & response.status)
    return parseAndDigestJson(response.body())
  except:
    raise newException(ValueError,
                       msg & " failed to fetch manifest via www-authenticate challenge: " &
                       getCurrentExceptionMsg())

template imageName(image: string): string =
  image.split(":")[0].split("@")[0]

proc setJson(self: DockerManifest, data: DigestedJson) =
  if self.digest != "" and self.digest != data.digest:
    raise newException(
      ValueError,
      "Fetched mismatched digest vs digest whats in parent manifest for: " & self.imageName,
    )
  if self.size > 0 and self.size != data.size:
    raise newException(
      ValueError,
      "Fetched mismatched json size vs whats in parent manifest for: " & self.imageName,
    )
  self.digest    = data.digest
  self.size      = data.size
  self.json      = data.json
  self.isFetched = true

proc setImageConfig(self: DockerManifest, data: DigestedJson) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image config on image manifests")
  let
    configJson = data.json{"config"}
    config     = DockerManifest(
      kind:      DockerManifestType.config,
      imageName: self.imageName,
      mediaType: configJson{"mediaType"}.getStr(),
      digest:    configJson{"digest"}.getStr(),
      size:      configJson{"size"}.getInt(),
      isFetched: false,
      image:     self,
    )
  self.config = config

proc setImagePlatform(self: DockerManifest, platform: DockerPlatform) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image platform on image manifests")
  if self.platform.os != "" and self.platform.architecture != "" and self.platform != platform:
    raise newException(
      ValueError,
      "Received mismatching docker image platforms from manifest and its config",
    )
  self.platform = self.config.configPlatform

proc setImageLayers(self: DockerManifest, data: DigestedJson) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image layers on image manifests")
  for layer in data.json{"layers"}.items():
    self.layers.add(DockerManifest(
      kind:         DockerManifestType.layer,
      imageName:    self.imageName,
      mediaType:    layer{"mediaType"}.getStr(),
      digest:       layer{"digest"}.getStr(),
      size:         layer{"size"}.getInt(),
      isFetched:    true,
    ))

proc fetch(self: DockerManifest) =
  if self.isFetched:
    return
  let manifestRef = self.imageName & "@" & self.digest
  case self.kind
  of DockerManifestType.image:
    let data = requestManifestJson(manifestRef)
    self.setJson(data)
    self.setImageConfig(data)
    self.setImageLayers(data)
    self.config.fetch()
    self.setImagePlatform(self.config.configPlatform)
  of DockerManifestType.config:
    let data = requestManifestJson(manifestRef)
    self.setJson(data)
    # config object does not contain size so we add compressed size
    # for easier metadata collection
    self.json["compressedSize"] = %(self.image.getCompressedSize())
    self.imageConfig = self.json{"config"}
    self.configPlatform = (
      os:           data.json{"os"}.getStr(),
      architecture: data.json{"architecture"}.getStr(),
    )
  else:
    discard

proc newManifest(image: string, data: DigestedJson): DockerManifest =
  let
    name = imageName(image)
    json = data.json

  if "manifests" in json:
    trace("docker: " & image & " is a manifest list")
    let list = DockerManifest(
      kind:      DockerManifestType.list,
      imageName: name,
      mediaType: json{"mediaType"}.getStr(),
      manifests: @[],
    )
    list.setJson(data)
    for item in json["manifests"].items():
      let platform = item{"platform"}
      list.manifests.add(DockerManifest(
        kind:      DockerManifestType.image,
        imageName: name,
        mediaType: item{"mediaType"}.getStr(),
        digest:    item{"digest"}.getStr(),
        size:      item{"size"}.getInt(),
        isFetched: false,
        platform:  (
          os:           platform{"os"}.getStr(),
          architecture: platform{"architecture"}.getStr(),
        ),
      ))
    return list

  elif "config" in json and "layers" in json:
    trace("docker: " & image & " is an image manifest")
    let image = DockerManifest(
      kind:           DockerManifestType.image,
      imageName:      name,
      mediaType:      json{"mediaType"}.getStr(),
    )
    image.setJson(data)
    image.setImageConfig(data)
    image.setImageLayers(data)
    return image

  elif "config" in json and "mediaType" notin json:
    raise newException(ValueError, "docker config manifest can only be created from an image")

  elif "layer" in json{"mediaType"}.getStr():
    raise newException(ValueError, "docker layer manifest can only be created from an image")

  else:
    raise newException(ValueError, "Unsupported docker manifest json")

proc fetchManifest(image: string): DockerManifest =
  ## request either manifest list or image manifest for specified image
  # keep in mind that image can be of multiple formats
  # foo                   # image manifest name
  # foo:tag               # manifest for specific tag
  # foo@sha256:<checksum> # pinned to specific digest
  # therefore we gracefully handle each possibility
  let data = requestManifestJson(image)
  result = newManifest(image, data)
  result.fetch()

proc fetchImageManifest*(image: string, platform: string): DockerManifest =
  let platformTuple = parseDockerPlatform(platform)
  var manifest = fetchManifest(image)
  if manifest.kind == DockerManifestType.list:
    manifest = manifest.findPlatformManifest(platformTuple)
    manifest.fetch()
  if manifest.platform != platformTuple:
    raise newException(ValueError, "Could not find manifest for: " & platform)
  return manifest
