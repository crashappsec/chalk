##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for interacting with remote registry docker manifests

import std/[
  algorithm,
  json,
]
import ".."/[
  types,
  utils/base64,
  utils/http,
  utils/json,
  utils/semver,
  utils/strings,
  utils/www_authenticate,
]
import "."/[
  exe,
  ids,
  json,
  registry,
]

type FilterManifests = ref object
  manifests: seq[DockerManifest]
  filters:   seq[string]

# cache is by repo ref as its normalized in buildx imagetools command
var
  jsonCache     = initTable[string, DigestedJson]()
  manifestCache = initTable[string, DockerManifest]()

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

proc setJson(self:   DockerManifest,
             data:   DigestedJson,
             check = true,
             ) =
  if check:
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
  if data.json != nil:
    self.json    = data.json

proc mimickLocalConfig(self: DockerManifest) =
  ## set additional json fields for easier metadata collection
  ## to match local docker inspect json output
  if self.kind != DockerManifestType.config:
    raise newException(AssertionDefect, "can only mimick config json on config manifest")
  if isDockerOverlayFS():
    self.json["id"] = %(self.image.digest.extractDockerHash())
  else:
    self.json["id"] = %(self.digest.extractDockerHash())
  # config object does not contain size so we add compressed size
  # for easier metadata collection
  self.json["compressedSize"] = %(self.image.getCompressedSize())
  if "config" notin self.json:
    self.json["config"] = newJObject()
  self.json["config"]["digest"] = %(self.digest)
  if self.image.annotations != nil:
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

proc setImagePlatform(self:     DockerManifest,
                      platform: DockerPlatform,
                      check   = true,
                      ) =
  if self.kind != DockerManifestType.image:
    raise newException(AssertionDefect, "can only set image platform on image manifests")
  if self.platform.isKnown() and self.platform != platform:
    let msg = (
      "Received mismatching docker image platforms from manifest and its config " &
      $self.platform & " != " & $platform
    )
    if check:
      raise newException(ValueError, msg)
    else:
      trace("docker: " & msg)
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

proc fetch(self:            DockerManifest,
           fetchConfig    = true,
           fetchManifests = false,
           checkJson      = true,
           checkPlatform  = true,
           ): DockerManifest {.discardable.} =
  result = self
  case self.kind
  of DockerManifestType.list:
    if fetchManifests:
      for i in self.manifests:
        i.fetch(fetchConfig = fetchConfig)
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
      self.setJson(data, check = checkJson)
      self.setAnnotations(data.json)
      self.setImageConfig(data)
      self.setImageLayers(data)
    if fetchConfig:
      self.config.fetch()
      self.setImagePlatform(self.config.configPlatform, check = checkPlatform)
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
    self.setJson(data, check = checkJson)
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
        kind:         DockerManifestType.image,
        name:         name,
        list:         list,
        mediaType:    item{"mediaType"}.getStr(),
        artifactType: json{"artifactType"}.getStr(),
        digest:       item{"digest"}.getStr(),
        size:         item{"size"}.getInt(),
        platform:     DockerPlatform(
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
      artifactType:   json{"artifactType"}.getStr(),
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

proc link*(self: DockerManifest): DockerManifest {.discardable.} =
  case self.kind
  of DockerManifestType.layer:
    discard
  of DockerManifestType.config:
    discard
  of DockerManifestType.image:
    if self.config != nil:
      self.config.image = self
      self.config.name = self.name
      self.config.link()
    for i in self.layers:
      i.name = self.name
      i.link()
  of DockerManifestType.list:
    for i in self.manifests:
      i.list = self
      i.name = self.name
      i.link()
  return self

proc asJson(self: DockerManifest): JsonNode =
  result = %*({
    "schemaVersion": 2,
    "mediaType":     self.mediaType,
  })
  if self.annotations != nil and len(self.annotations) > 0:
    result["annotations"] = self.annotations
  case self.kind
  of DockerManifestType.image,
     DockerManifestType.list:
    if self.artifactType != "":
      result["artifactType"] = %(self.artifactType)
  of DockerManifestType.config,
     DockerManifestType.layer:
    discard

proc asDescriptorJson(self: DockerManifest, withPlatform = true): JsonNode =
  if self == nil:
    return nil
  result = %*({
    "mediaType": self.mediaType,
    "digest":    self.digest,
    "size":      self.size,
  })
  if self.annotations != nil and len(self.annotations) > 0:
    result["annotations"] = self.annotations
  case self.kind
  of DockerManifestType.list:
    if self.artifactType != "":
      result["artifactType"] = %(self.artifactType)
  of DockerManifestType.image:
    if self.artifactType != "":
      result["artifactType"] = %(self.artifactType)
    if withPlatform and self.platform.isKnown():
      result["platform"] = self.platform.asJson()
  of DockerManifestType.config,
     DockerManifestType.layer:
    discard

proc updateJson(self: DockerManifest): JsonNode =
  # https://specs.opencontainers.org/image-spec/manifest/
  case self.kind
  of DockerManifestType.layer:
    discard
  of DockerManifestType.config:
    discard
  of DockerManifestType.image:
    var layers = newJArray()
    for i in self.layers:
      layers.add(i.asDescriptorJson())
    self.json = self.json.update(self.asJson())
    self.json["layers"] = layers
    self.json["config"] = self.json{"config"}.update(self.config.asDescriptorJson())
    if self.subject != nil:
      self.json["subject"] = self.json{"subject"}.update(self.subject.asDescriptorJson(withPlatform = false))
  of DockerManifestType.list:
    var manifests = newJArray()
    for i in self.manifests:
      manifests.add(i.asDescriptorJson())
    self.json = self.json.update(self.asJson())
    self.json["manifests"] = manifests
  return self.json

proc add*(self: DockerManifest, item: DockerManifest) =
  if self.kind != DockerManifestType.list:
    raise newException(ValueError, "can only add manifests to list manifest")
  if item.kind != DockerManifestType.image:
    raise newException(ValueError, "Can only add image manfiests to list manifest")
  self.manifests.add(item)
  self.isFetched = false
  self.link()

proc allImages*(self: DockerManifest): FilterManifests =
  case self.kind
  of DockerManifestType.list:
    return FilterManifests(
      manifests: self.manifests,
      filters:   @[],
    )
  of DockerManifestType.image:
    if self.list != nil:
      return FilterManifests(
        manifests: self.list.manifests,
        filters:   @[],
      )
    return FilterManifests(
      manifests: @[self],
      filters:   @[],
    )
  else:
    raise newException(ValueError, "only list or image manifests can normalize to manifests")

proc allLayers*(self: DockerManifest): FilterManifests =
  case self.kind
  of DockerManifestType.image:
    return FilterManifests(
      manifests: self.layers,
      filters:   @[],
    )
  else:
    raise newException(ValueError, "only image manifests has layers")

proc filterKnownPlatforms*(self: FilterManifests,
                           ): FilterManifests =
  ## find all valid platform images
  ## as list manifest could have additional things in the list which are
  ## not images such as provenance/sbom blobs
  let manifests = self.manifests
  self.manifests = @[]
  self.filters.add("--platform")
  for i in manifests:
    if i.platform.isKnown():
      self.manifests.add(i)
  return self

proc filterByPlatforms*(self:      FilterManifests,
                        platforms: openArray[DockerPlatform],
                        fetch    = true,
                        ): FilterManifests =
  let platforms = platforms.known()
  if len(platforms) == 0:
    return self
  for i in platforms:
    self.filters.add("--platform=" & $i)
  let manifests = self.manifests
  self.manifests = @[]
  for i in manifests:
    if i.platform.isKnown() and i.platform in platforms:
      self.manifests.add(i)
  # if no matching platforms are found there is a possibility
  # the list manifest had the wrong platform
  # hence we explicitly refetch the platform from the
  # image config object
  # see https://github.com/moby/buildkit/issues/6518
  if len(self.manifests) == 0 and fetch:
    for i in manifests:
      i.fetch(fetchConfig = true, checkPlatform = false)
      if i.platform.isKnown() and i.platform in platforms:
        self.manifests.add(i)
  return self

proc ifManyFilterBySystemPlatform*(self: FilterManifests,
                                   enabled = true,
                                   fetch   = true,
                                   ): FilterManifests =
  if enabled and len(self.manifests) > 1:
    return self.filterByPlatforms(@[getSystemBuildPlatform()], fetch = fetch)
  return self

proc filterByAnyAnnotation*(self:        FilterManifests,
                            annotations: openArray[(string, string)],
                            fetch      = false,
                            ): FilterManifests =
  if len(annotations) == 0:
    return self
  var filters = newSeq[string]()
  for (k, v) in annotations:
    filters.add(k & "=" & v)
  self.filters.add("--annotation=OR(" & filters.join(", ") & ")")
  let manifests = self.manifests
  self.manifests = @[]
  for i in manifests:
    if fetch:
      i.fetch()
    if i.annotations == nil:
      continue
    for (k, v) in annotations:
      if i.annotations{k}.getStr().toLower().startsWith(v.toLower()):
        self.manifests.add(i)
        break
  return self

proc filterByAllAnnotations*(self:        FilterManifests,
                             annotations: openArray[(string, string)],
                             fetch      = false,
                             ): FilterManifests =
  if len(annotations) == 0:
    return self
  var filters = newSeq[string]()
  for (k, v) in annotations:
    filters.add(k & "=" & v)
  self.filters.add("--annotation=AND(" & filters.join(", ") & ")")
  let manifests = self.manifests
  self.manifests = @[]
  for i in manifests:
    if fetch:
      i.fetch()
    if i.annotations == nil:
      continue
    var matched = true
    for (k, v) in annotations:
      if not i.annotations{k}.getStr().toLower().startsWith(v.toLower()):
        matched = false
        break
    if matched:
      self.manifests.add(i)
  return self

proc sortByAnnotation*(self:       FilterManifests,
                       annotation: string,
                       fetch       = false,
                       ): FilterManifests =
  let manifests = self.manifests
  self.manifests = @[]
  for i in manifests:
    if fetch:
      i.fetch()
    if i.annotations == nil:
      continue
    if annotation in i.annotations:
      self.manifests.add(i)
  self.manifests = self.manifests.sortedByIt((it.annotations{annotation}.getStr(),)).reversed()
  return self

proc one*(self: FilterManifests): DockerManifest =
  case len(self.manifests)
  of 0:
    raise newException(KeyError, "there are no manifests matching " & $self.filters)
  of 1:
    return self.manifests[0]
  else:
    raise newException(KeyError, "there are multiple manifests matching " & $self.filters)

proc first*(self: FilterManifests): DockerManifest =
  case len(self.manifests)
  of 0:
    raise newException(KeyError, "there are no manifests matching " & $self.filters)
  else:
    return self.manifests[0]

proc all*(self: FilterManifests): seq[DockerManifest] =
  return self.manifests

proc fetchManifest*(name:            DockerImage,
                    fetchConfig    = true,
                    fetchManifests = false,
                    ): DockerManifest =
  ## request either manifest list or image manifest for specified image
  # keep in mind that image can be of multiple formats
  # foo                   # image manifest name
  # foo:tag               # manifest for specific tag
  # foo@sha256:<checksum> # pinned to specific digest
  # therefore we gracefully handle each possibility
  var cacheKeys = @[name.asRepoRef()]
  if name.digest != "":
    cacheKeys.add(name.asRepoDigest())
  if name.tag != "":
    cacheKeys.add(name.asRepoTag())
  for key in cacheKeys:
    if key in manifestCache:
      result = manifestCache[key]
      result.fetch(fetchConfig = fetchConfig, fetchManifests = fetchManifests)
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
  result.fetch(fetchConfig = fetchConfig, fetchManifests = fetchManifests)
  if name.digest != "":
    manifestCache[name.asRepoDigest()] = result
  elif name.tag != "":
    manifestCache[name.asRepoTag()] = result
  else:
    manifestCache[name.asRepoRef()] = result
  if result.kind == DockerManifestType.list:
    for image in result.manifests:
      manifestCache[image.asImage().asRepoDigest()] = image

proc fetchListManifest*(name:            DockerImage,
                        platforms:       seq[DockerPlatform] = @[],
                        fetchConfig    = false,
                        fetchManifests = false,
                        ): DockerManifest =
  result = fetchManifest(name, fetchConfig = fetchConfig, fetchManifests = fetchManifests)
  if result.kind != DockerManifestType.list:
    raise newException(ValueError, "No manifest list for " & $name)
  if len(platforms) == 0:
    return
  let found = result.allImages().filterByPlatforms(platforms).all()
  if len(found) < len(platforms):
    raise newException(ValueError, "Could not find all platforms for " & $name & " " & $($platforms))

proc fetchImageManifest*(name:                  DockerImage,
                         platform:              DockerPlatform,
                         ifManySystemPlatform = false,
                         fetchConfig          = true,
                         fetchManifests       = false,
                         ): DockerManifest =
  trace("docker: fetching image manifest for: " & $name & " for " & $platform)
  var manifest = fetchManifest(name, fetchConfig = fetchConfig, fetchManifests = fetchManifests)
  if manifest.kind == DockerManifestType.list:
    manifest = (
      manifest
      .allImages()
      .filterByPlatforms(@[platform])
      .ifManyFilterBySystemPlatform(ifManySystemPlatform)
      .one()
    )
    manifest.fetch()
  if manifest.kind != DockerManifestType.image:
    raise newException(ValueError, "Could not find image manifest for: " & $name)
  if platform.isKnown() and manifest.platform != platform:
    raise newException(
      ValueError,
      "Could not fetch manifest for: " & $name & " " &
      $platform & " != " & "" & $manifest.platform
    )
  return manifest

proc fetchListOrImageManifest*(name:            DockerImage,
                               platforms:       seq[DockerPlatform] = @[],
                               fetchConfig    = true,
                               fetchManifests = false,
                               ): DockerManifest =
  case len(platforms)
  of 0:
    result = fetchManifest(name, fetchConfig = fetchConfig, fetchManifests = fetchManifests)
    case result.kind
    of DockerManifestType.image, DockerManifestType.list:
      discard
    else:
      raise newException(ValueError, "could not find list or image manifest for " & $name)
  of 1:
    let image = fetchImageManifest(
      name,
      platforms[0],
      fetchConfig    = fetchConfig,
      fetchManifests = fetchManifests,
    )
    if image.list != nil:
      return image.list
    return image
  else:
    return fetchListManifest(name, platforms)

proc put*(self: DockerManifest) =
  if self.isFetched:
    return
  trace("docker: uploading to registry " & $self.kind & " " & self.mediaType)
  case self.kind
  of DockerManifestType.layer:
    if self.fileStream != nil:
      self.setJson(
        layerPutFileStream(
          layer       = self.name,
          contentType = self.mediaType,
          fileStream  = self.fileStream,
        ),
        check = false,
      )
    else:
      self.setJson(
        layerPutJson(
          layer       = self.name,
          contentType = self.mediaType,
          data        = self.updateJson(),
        ),
        check = false,
      )
  of DockerManifestType.config:
    self.setJson(
      layerPutJson(
        layer       = self.name,
        contentType = self.mediaType,
        data        = self.updateJson(),
      ),
      check = false,
    )
  of DockerManifestType.image:
    if self.config != nil:
      self.config.put()
    for i in self.layers:
      i.put()
    self.setJson(
      manifestPut(
        image       = self.name,
        contentType = self.mediaType,
        data        = self.updateJson(),
        byTag       = self.name.tag != "" and self.list == nil,
      ),
      check = false,
    )
  of DockerManifestType.list:
    for i in self.manifests:
      i.put()
    self.setJson(
      manifestPut(
        image       = self.name,
        contentType = self.mediaType,
        data        = self.updateJson(),
        byTag       = self.name.tag != "",
      ),
      check = false,
    )

proc findSibling(self: DockerManifest, reference = "attestation-manifest"): DockerManifest =
  return (
    self.allImages()
    .filterByAllAnnotations({
      "vnd.docker.reference.type":   reference,
      "vnd.docker.reference.digest": self.asImage().imageRef,
    })
    .first()
    .fetch()
  )

proc findInTotoLayer(self: DockerManifest, predicate: string): DockerManifest =
  return (
    self.allLayers()
    .filterByAllAnnotations({
      "in-toto.io/predicate-type": predicate,
    })
    .first()
  )

proc fetchProvenance*(name: DockerImage, platform: DockerPlatform): JsonNode =
  # https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/
  try:
    trace("docker: looking up provenance for: " & $name)
    let layer =
      name.fetchImageManifest(platform)
      .findSibling()
      .findInTotoLayer("https://slsa.dev/provenance/")
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
    let layer =
      name.fetchImageManifest(platform)
      .findSibling()
      .findInTotoLayer("https://spdx.dev/Document")
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

proc getMarkFromInTotoStatement(statement: JsonNode,
                                subject:   DockerImage,
                                ): string =
  let
    predicateType = statement{"predicateType"}.getStr()
    predicate     = statement{"predicate"}.assertIs(JObject, "Bad in-toto statement predicate type")
    subjects      = statement{"subject"}.assertIs(JArray, "Bad in-toto statement subject type")

  for i in subjects.items():
    i.assertIs(JObject, "Bad in-toto subject type")
    let digest = i{"digest"}.assertIs(JObject, "Bad in-toto subject digest"){"sha256"}.getStr()
    if digest.extractDockerHash() != subject.digest:
      raise newException(
        ValueError,
        "In-Toto attestation subject does not match any known image digest: " &
        digest & " != " & subject.digest
      )

  case predicateType
  of "https://cosign.sigstore.dev/attestation/v1":
    let
      data   = predicate{"Data"}.getStr().strip()
      nested = parseJson(data).assertIs(JObject, "Bad in-toto statement predicate data type")
    return nested.getMarkFromInTotoStatement(subject)

  of "https://in-toto.io/attestation/scai/attribute-report/v0.2":
    let attributes = (
      predicate{"attributes"}
      .assertIs(JArray, "Bad in-toto statement attributes type")
      .assertHasLen("In-toto statement predicate doesnt have any attributes")
    )
    for i in attributes.items():
      i.assertIs(JObject, "Bad in-toto statement predicate attribute type")
      if i{"attribute"}.getStr() == "CHALK":
        result = i{"evidence"}.getStr()

  of "https://in-toto.io/attestation/scai/v0.3":
    let attributes = (
      predicate{"attributes"}
      .assertIs(JArray, "Bad in-toto statement attributes type")
      .assertHasLen("In-toto statement predicate doesnt have any attributes")
    )
    for i in attributes.items():
      i.assertIs(JObject, "Bad in-toto statement predicate attribute type")
      if i{"attribute"}.getStr() == "CHALK":
        result = $i{"evidence"}.assertIs(JObject, "Bad in-toto statement predicate CHALK attribute type")

  else:
    raise newException(ValueError, "Unsupported in-toto predicate type " & predicateType)

proc getMarkFromDsseInToto(dsse:    JsonNode,
                           subject: DockerImage,
                           ): string =
  dsse.assertIs(JObject, "Bad in-toto envelope type")
  let payloadType = dsse{"payloadType"}.getStr()
  case payloadType
  of "application/vnd.in-toto+json":
    let statement = parseJson(base64.safeDecode(dsse{"payload"}.getStr()))
    return statement.getMarkFromInTotoStatement(subject)
  else:
    raise newException(ValueError, "Unsupported in-toto envelope DSSE type " & payloadType)

iterator fetchCosignDsseInTotoMark(image: DockerImage): (JsonNode, string) =
  let spec = image.asCosignAttestation()
  trace("docker: getting intoto statement from cosign sigstore attestation for " & $spec)
  # in cosign v2 there could only be one image but it could have multiple layers
  # whenever same image is attested multiple times in which case we attempt
  # to extract it from all of them
  let manifest = (
    fetchListOrImageManifest(spec, fetchConfig = false)
    .allImages()
    .one()
  )
  for layer in (
      manifest
      .allLayers()
      .filterByAllAnnotations(
        {
          "predicateType": "https://cosign.sigstore.dev/attestation/v1",
        },
        fetch = true,
      )
      .all()
  ):
    try:
      let dsse = (
        layer.asImage()
        .layerGetJson(accept = layer.mediaType)
        .json
        .assertIs(JObject, "Bad dsse in-toto envelope type")
      )
      yield (dsse, dsse.getMarkFromDsseInToto(image))
    except:
      trace("docker: could not get intoto statement from cosign sigstore attestation from " &
            $image & " due to " & getCurrentExceptionMsg())

iterator fetchOCIDsseInTotoMark(image: DockerImage): (JsonNode, string) =
  let spec = image.asOciAttestation()
  trace("docker: getting intoto statement from cosign OCI attestation for " & $spec)
  # in cosign v3 which uses OCI there could be multiple manifests
  # but each having only one attestation layer
  for manifest in (
    fetchListOrImageManifest(spec, fetchConfig = false)
    .allImages()
    .filterByAllAnnotations(
      {
        "dev.sigstore.bundle.predicateType": "https://sigstore.dev/cosign/sign/v1",
      },
      fetch = true,
    )
    .sortByAnnotation(
      "org.opencontainers.image.created",
      fetch = true,
    )
    .all()
  ):
    let layer = manifest.allLayers().one()
    try:
      let
        envelope = (
          layer.asImage()
          .layerGetJson(accept = layer.mediaType)
          .json
          .assertIs(JObject, "Bad in-toto bundle type")
        )
        dsse = (
          envelope{"dsseEnvelope"}
          .assertIs(JObject, "Bad dsse in-toto envelope type")
        )
      yield (dsse, dsse.getMarkFromDsseInToto(image))
    except:
      trace("docker: could not get intoto statement from OCI attestation from " &
            $image & " due to " & getCurrentExceptionMsg())

iterator fetchDsseInTotoMark*(image:        DockerImage,
                              fetchOci    = true,
                              fetchCosign = true,
                              ): (JsonNode, string) =
  if fetchOci:
    try:
      for (dsse, mark) in image.fetchOCIDsseInTotoMark():
        yield (dsse, mark)
    except:
      trace("docker: could not get intoto statement from OCI attestation from " &
            $image & " due to " & getCurrentExceptionMsg())
  if fetchCosign:
    try:
      for (dsse, mark) in image.fetchCosignDsseInTotoMark():
        yield (dsse, mark)
    except:
      trace("docker: could not get intoto statement from sigstore attestation from " &
            $image & " due to " & getCurrentExceptionMsg())
