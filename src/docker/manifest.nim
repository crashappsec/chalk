##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for interacting with remote registry docker manifests

import std/[httpclient]
import ".."/[config, www_authenticate, semver, util]
import "."/[exe, json, ids, registry]

# cache is by repo ref as its normalized in buildx imagetools command
var
  jsonCache     = initTable[string, DigestedJson]()
  manifestCache = initTable[string, DockerManifest]()

proc findAllPlatformsManifests(self: DockerManifest,
                               platforms: seq[DockerPlatform] = @[],
                               ): seq[DockerManifest] =
  ## find all valid platform images from the manifest list
  ## as manifest could have additional things in the list which are
  ## not images such as provenance/sbom blobs
  if self.kind != DockerManifestType.list:
    raise newException(AssertionDefect, "can only find platform images from manifest list")
  result = @[]
  for manifest in self.manifests:
    if manifest.platform.isKnown():
      if len(platforms) > 0 and manifest.platform notin platforms:
        continue
      result.add(manifest)

proc findPlatformManifest(self: DockerManifest, platform: DockerPlatform): DockerManifest =
  if self.kind != DockerManifestType.list:
    raise newException(AssertionDefect, "can only find platform manifest from manifest list")
  for manifest in self.manifests:
    if manifest.platform == platform:
      return manifest
  raise newException(KeyError, "Could not find manifest for: " & $self.name & " --platform=" & $platform)

proc getCompressedSize(self: DockerManifest): int =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "compressed image size can only be computed on image manifest")
  result = 0
  for layer in self.layers:
    result += layer.size

proc requestManifestJson(name: DockerImage, flags = @["--raw"], fallback = true): DigestedJson =
  ## fetch raw json manifest via docker imagetools
  ## however if that fails withs 401 error, attept to manually
  ## fetch the manifest via the URL from the error message
  ## as the error could be due to www-authenticate challenge
  if not hasBuildX():
    raise newException(ValueError, "No buildx to iteract with registry")
  let key = name.asRepoDigest() & $flags
  if key in jsonCache:
    return jsonCache[key]
  let
    msg = "docker: requesting manifest for: " & $name
    args   = @["buildx", "imagetools", "inspect", name.asRepoRef()] & flags
  trace("docker: docker " & args.join(" "))
  let
    output = runDockerGetEverything(args)
    stdout = output.getStdout()
    stderr = output.getStderr()
    text   = stdout & stderr
  if output.getExit() == 0:
    try:
      let value = parseAndDigestJson(stdout)
      if value.json.kind == JNull:
        raise newException(ValueError, msg & " didnt return valid json: " & $value.json)
      jsonCache[key] = value
      return value
    except:
      raise newException(ValueError, msg & " failed with: " & getCurrentExceptionMsg())
  elif not fallback:
    raise newException(ValueError, msg & " exited with: " & $output.getExit())
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
  try:
    let response = authSafeRequest(url)
    if not response.code().is2xx():
      raise newException(ValueError, msg & " manifest was not returned from URL: " & response.status)
    let value = parseAndDigestJson(response.body())
    jsonCache[key] = value
    return value
  except:
    raise newException(ValueError,
                       msg & " failed to fetch manifest via www-authenticate challenge: " &
                       getCurrentExceptionMsg())

proc setJson(self: DockerManifest, data: DigestedJson) =
  if self.digest != "" and self.digest != data.digest:
    raise newException(
      ValueError,
      "Fetched mismatched digest vs digest whats in parent manifest for: " & $self.name,
    )
  if self.size > 0 and self.size != data.size:
    raise newException(
      ValueError,
      "Fetched mismatched json size vs whats in parent manifest for: " & $self.name,
    )
  self.digest    = data.digest
  self.size      = data.size
  self.json      = data.json

proc mimickLocalConfig(self: DockerManifest) =
  ## set additional json fields for easier metadata collection
  ## to match local docker inspect json output
  if self.kind != DockerManifestType.config:
    raise newException(AssertionDefect, "can only mimick config json on config manifest")
  self.json["id"] = %(self.digest.extractDockerHash())
  # config object does not contain size so we add compressed size
  # for easier metadata collection
  self.json["compressedSize"] = %(self.image.getCompressedSize())
  if self.image.annotations != nil:
    if "config" notin self.json:
      self.json["config"] = newJObject()
    self.json["config"]["annotations"] = self.image.annotations

proc setImageConfig(self: DockerManifest, data: DigestedJson) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image config on image manifests")
  let
    configJson = data.json{"config"}
    config     = DockerManifest(
      kind:       DockerManifestType.config,
      name:       self.name,
      mediaType:  configJson{"mediaType"}.getStr(),
      digest:     configJson{"digest"}.getStr(),
      size:       configJson{"size"}.getInt(),
      image:      self,
    )
  self.config = config

proc setAnnotations(self: DockerManifest, data: JsonNode): DockerManifest {.discardable.} =
  self.annotations = self.annotations.update(data{"annotations"})
  return self

proc setImagePlatform(self: DockerManifest, platform: DockerPlatform) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image platform on image manifests")
  if self.platform.isKnown() and self.platform != platform:
    raise newException(
      ValueError,
      "Received mismatching docker image platforms from manifest and its config",
    )
  self.platform = platform

proc setImageLayers(self: DockerManifest, data: DigestedJson) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image layers on image manifests")
  self.layers = @[]
  for layer in data.json{"layers"}.items():
    self.layers.add(DockerManifest(
      kind:          DockerManifestType.layer,
      name:          self.name,
      mediaType:     layer{"mediaType"}.getStr(),
      digest:        layer{"digest"}.getStr(),
      size:          layer{"size"}.getInt(),
    ).setAnnotations(layer))

proc fetch(self: DockerManifest, fetchConfig = true): DockerManifest {.discardable.} =
  result = self
  case self.kind
  of DockerManifestType.image:
    if not self.isFetched:
      let data =
        try:
          manifestGet(self.asImage(), self.mediaType)
        except RegistryResponseError:
          trace("docker: " & getCurrentExceptionMsg())
          raise
        except:
          error("docker: " & getCurrentExceptionMsg())
          requestManifestJson(self.asImage())
      self.setJson(data)
      self.setAnnotations(data.json)
      self.setImageConfig(data)
      self.setImageLayers(data)
    if fetchConfig:
      self.config.fetch()
      self.setImagePlatform(self.config.configPlatform)
  of DockerManifestType.config:
    if self.isFetched:
      return
    let data =
      try:
        layerGetJson(self.asImage(), self.mediaType)
      except RegistryResponseError:
        trace("docker: " & getCurrentExceptionMsg())
        raise
      except:
        error("docker: " & getCurrentExceptionMsg())
        requestManifestJson(self.asImage())
    self.setJson(data)
    self.setAnnotations(data.json)
    self.mimickLocalConfig()
    self.configPlatform = DockerPlatform(
      os:           data.json{"os"}.getStr(),
      architecture: data.json{"architecture"}.getStr(),
      variant:      data.json{"variant"}.getStr(),
    )
  else:
    discard
  self.isFetched = true

proc newManifest(name: DockerImage, data: DigestedJson): DockerManifest =
  let json = data.json

  if "manifests" in json:
    trace("docker: " & $name & " is a manifest list")
    let list = DockerManifest(
      kind:       DockerManifestType.list,
      name:       name,
      mediaType:  json{"mediaType"}.getStr(),
      manifests:  @[],
    )
    list.setJson(data)
    list.setAnnotations(json)
    for item in json["manifests"].items():
      let platform = item{"platform"}
      list.manifests.add(DockerManifest(
        kind:        DockerManifestType.image,
        name:        name,
        list:        list,
        mediaType:   item{"mediaType"}.getStr(),
        digest:      item{"digest"}.getStr(),
        size:        item{"size"}.getInt(),
        platform:    DockerPlatform(
          os:           platform{"os"}.getStr(),
          architecture: platform{"architecture"}.getStr(),
          variant:      platform{"variant"}.getStr(),
        )
      ).setAnnotations(item))
    return list

  elif "config" in json and "layers" in json:
    trace("docker: " & $name & " is an image manifest")
    let image = DockerManifest(
      kind:           DockerManifestType.image,
      name:           name,
      mediaType:      json{"mediaType"}.getStr(),
    )
    image.setJson(data)
    image.setAnnotations(json)
    image.setImageConfig(data)
    image.setImageLayers(data)
    return image

  elif "config" in json and "mediaType" notin json:
    raise newException(ValueError, "docker config manifest can only be created from an image")

  elif "layer" in json{"mediaType"}.getStr():
    raise newException(ValueError, "docker layer manifest can only be created from an image")

  else:
    raise newException(ValueError, "Unsupported docker manifest json")

proc fetchManifest*(name: DockerImage,
                    fetchConfig = true): DockerManifest =
  ## request either manifest list or image manifest for specified image
  # keep in mind that image can be of multiple formats
  # foo                   # image manifest name
  # foo:tag               # manifest for specific tag
  # foo@sha256:<checksum> # pinned to specific digest
  # therefore we gracefully handle each possibility
  for key in @[name.asRepoDigest(), name.asRepoTag(), name.asRepoRef()]:
    if key in manifestCache:
      result = manifestCache[key]
      result.fetch(fetchConfig = fetchConfig)
      return result
  try:
    let
      meta = manifestHead(name)
      data = manifestGet(name.withDigest(meta.digest), meta.mediaType)
    result = newManifest(name, data)
  except RegistryResponseError:
    trace("docker: " & getCurrentExceptionMsg())
    raise
  except:
    error("docker: " & getCurrentExceptionMsg())
    let data = requestManifestJson(name)
    result = newManifest(name, data)
  result.fetch(fetchConfig = fetchConfig)
  if name.digest != "":
    manifestCache[name.asRepoDigest()] = result
  elif name.tag != "":
    manifestCache[name.asRepoTag()] = result
  else:
    manifestCache[name.asRepoRef()] = result
  if result.kind == DockerManifestType.list:
    for image in result.manifests:
      manifestCache[image.asImage().asRepoDigest()] = image

proc fetchListManifest*(name: DockerImage, platforms: seq[DockerPlatform] = @[]): DockerManifest =
  result = fetchManifest(name, fetchConfig = false)
  if result.kind != DockerManifestType.list:
    raise newException(ValueError, "No manifest list for " & $name)
  if len(platforms) == 0:
    return
  let found = result.findAllPlatformsManifests(platforms)
  if len(found) < len(platforms):
    raise newException(ValueError, "Could not find all platforms for " & $name & " " & $($platforms))

proc fetchOnlyImageManifest*(name: DockerImage, fetchConfig = true): DockerManifest =
  var manifest = fetchManifest(name, fetchConfig = fetchConfig)
  if manifest.kind == DockerManifestType.list:
    let manifests = manifest.findAllPlatformsManifests()
    if len(manifests) == 1:
      manifest = manifests[0]
    else:
      raise newException(KeyError, "There are multiple platform images for: " & $name)
  if manifest.kind != DockerManifestType.image:
    raise newException(ValueError, "Could not find image manifest for: " & $name)
  manifest.fetch(fetchConfig = fetchConfig)
  return manifest

proc fetchImageManifest*(name: DockerImage,
                         platform: DockerPlatform,
                         ): DockerManifest =
  trace("docker: fetching image manifest for: " & $name)
  var manifest = fetchManifest(name)
  if manifest.kind == DockerManifestType.list:
    manifest = manifest.findPlatformManifest(platform)
    manifest.fetch()
  if manifest.kind != DockerManifestType.image:
    raise newException(ValueError, "Could not find image manifest for: " & $name)
  if manifest.platform != platform:
    raise newException(
      ValueError,
      "Could not fetch manifest for: " & $name & " " &
      $platform & " != " & "" & $manifest.platform
    )
  return manifest

proc fetchListOrImageManifest*(name: DockerImage, platforms: seq[DockerPlatform] = @[]): DockerManifest =
  if len(platforms) > 1:
    return fetchListManifest(name, platforms)
  let
    platform = platforms[0]
    image    = fetchImageManifest(name, platform)
  if image.list != nil:
    return image.list
  return image

proc findSibling(self: DockerManifest, reference = "attestation-manifest"): DockerManifest =
  if self.kind != DockerManifestType.image:
    raise newException(ValueError, "Can only lookup sibling for image manifest")
  if self.list == nil:
    raise newException(ValueError, "Need reference to list manifest to lookup sibling")
  for i in self.list.manifests:
    if i.annotations == nil:
      continue
    if (
      i.annotations{"vnd.docker.reference.type"}.getStr().toLower() == reference.toLower() and
      i.annotations{"vnd.docker.reference.digest"}.getStr().toLower() == self.asImage().imageRef.toLower()
    ):
      return i.fetch()
  raise newException(KeyError, "Could not find sibling image of reference type: " & reference)

proc findInTotoLayer(self: DockerManifest, predicate: string): DockerManifest =
  if self.kind != DockerManifestType.image:
    raise newException(ValueError, "Can only lookup layers in image manifest")
  for l in self.layers:
    if l.annotations == nil:
      continue
    if l.annotations{"in-toto.io/predicate-type"}.getStr().toLower().startsWith(predicate.toLower()):
      return l
  raise newException(KeyError, "Could not find in-toto layer for predicate: " & predicate)

proc fetchProvenance*(name: DockerImage, platform: DockerPlatform): JsonNode =
  # https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/
  try:
    trace("docker: looking up provenance for: " & $name)
    let layer = name.fetchImageManifest(platform).findSibling().findInTotoLayer("https://slsa.dev/provenance/")
    result = layer.asImage().layerGetJson(accept = layer.mediaType).json{"predicate"}
    trace("docker: in registry found provenance for: " & $name)
  except RegistryResponseError, KeyError:
    trace("docker: " & getCurrentExceptionMsg())
    raise
  except:
    error("docker: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    # https://github.com/docker/buildx/releases/tag/v0.13.0
    if getBuildXVersion() < parseVersion("0.13"):
      raise newException(ValueError, "buildx 0.13 is required to collect provenance via imagetools")
    try:
      # for single-platform manifests, there is only a single provenance
      return requestManifestJson(
        name,
        flags    = @["--format", "{{json .Provenance.SLSA}}"],
        fallback = false,
      ).json
    except:
      # for multi-platform we have to filter on the platform
      # note index only supports a few keys so have to manually
      # take SLSA key
      return requestManifestJson(
        name,
        flags    = @["--format", "{{json (index .Provenance \"" & $platform & "\")}}"],
        fallback = false,
      ).json{"SLSA"}

proc fetchSBOM*(name: DockerImage, platform: DockerPlatform): JsonNode =
  # https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/
  try:
    trace("docker: looking up SBOM for: " & $name)
    let layer = name.fetchImageManifest(platform).findSibling().findInTotoLayer("https://spdx.dev/Document")
    result = layer.asImage().layerGetJson(accept = layer.mediaType).json{"predicate"}
    trace("docker: in registry found SBOM for: " & $name)
  except RegistryResponseError, KeyError:
    trace("docker: " & getCurrentExceptionMsg())
    raise
  except:
    error("docker: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    # https://github.com/docker/buildx/releases/tag/v0.13.0
    if getBuildXVersion() < parseVersion("0.13"):
      raise newException(ValueError, "buildx 0.13 is required to collect SBOM via imagetools")
    try:
      # for single-platform manifests, there is only a single sbom
      return requestManifestJson(
        name,
        flags    = @["--format", "{{json .SBOM.SPDX}}"],
        fallback = false,
      ).json
    except:
      # for multi-platform we have to filter on the platform
      # note index only supports a few keys so have to manually
      # take SPDX key
      return requestManifestJson(
        name,
        flags    = @["--format", "{{json (index .SBOM \"" & $platform & "\")}}"],
        fallback = false,
      ).json{"SPDX"}
