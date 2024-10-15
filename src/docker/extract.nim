##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## extract chalkmark json from images/containers into chalk object

import std/[base64]
import ".."/[attestation/utils, config, chalkjson, util]
import "."/[exe, inspect, ids, manifest, registry]

proc hasChalkLayer(self: ChalkObj): bool =
  result = false
  let layers = inspectHistoryCommands(self.imageId)
  for layer in layers:
    if "COPY " in layer and " /chalk.json" in layer:
      return true

proc hasChalkLayer(self: DockerManifest): bool =
  if self.kind != DockerManifestType.image:
    raise newException(ValueError, "Can only query chalk marks from manifest image. Given " & $self.kind)
  let history = self.config.json{"history"}
  if history == nil or history.kind != JArray or len(history) == 0:
    raise newException(ValueError, $self.name & " image config does not have valid history")
  let
    lastStep  = history[^1]
    createdBy = lastStep{"created_by"}.getStr()
  return "COPY" in createdBy and "/chalk.json" in createdBy

proc extractContainerMark(containerId: string): string =
  let (markStream, markTmp) = getNewTempFile(suffix = "chalk.json")
  markStream.close() # release fd so that docker can write to it
  let cpCmd = runDockerGetEverything(
    @["cp",
      containerId & ":" & "/chalk.json",
      markTmp],
    silent = false,
  )
  if cpCmd.exitCode != 0:
    trace("docker: " & containerId & ": could not cp /chalk.json from " &
          containerId & ": " & cpCmd.stdErr)
    if "No such container" in cpCmd.stdErr:
      raise newException(
        ValueError,
        containerId & ": container shut down before mark extraction",
      )
    elif "Could not find the file" in cpCmd.stdErr:
      raise newException(
        ValueError,
        containerId & ": container is unmarked.",
      )
    else:
      raise newException(
        ValueError,
        containerId & ": container mark not retrieved: " & cpCmd.stdErr,
      )
  result = tryToLoadFile(markTmp)
  if result == "":
    trace("docker: " & containerId & ": could not extract valid /chalk.json")
    raise newException(
      ValueError,
      containerId & ": invalid chalkmark extracted (empty string)"
    )

proc extractImageMark(self: ChalkObj): string =
  trace("docker: extracting chalk mark from " & self.imageId)

  # no layer has /chalk.json so image is not chalked
  # so dont bother extracting anything from it
  if not self.hasChalkLayer():
    trace("docker: " & self.imageId & ": no layer copies /chalk.json")
    raise newException(
      ValueError,
      self.imageId & ": is not chalked"
    )

  let
    createCmd = runDockerGetEverything(
      @["create",
        # need to specify some entrypoint in case image doesnt have ENTRYPOINT/CMD
        # but this entrypoint will never be executed so it can be any cmd
        "--entrypoint=false",
        self.imageId],
      silent = false,
    )
    containerId = createCmd.stdOut.strip()
  if createCmd.exitCode != 0:
    trace("docker: " & self.imageId & ": could not create container to extract /chalk.json: " &
          createCmd.stdErr)
    raise newException(
      ValueError,
      self.imageId & ": error extracting chalkmark"
    )

  try:
    return extractContainerMark(containerId)
  finally:
    discard runDockerGetEverything(@["rm", containerId])

proc extractMarkFromLayer(self: ChalkObj): string =
  var err = "no chalk mark found in any of the registry images"
  for image in self.images.uniq():
    let spec = image.withDigest(self.imageDigest)
    trace("docker: extract chalk mark from registry for " & $spec)
    try:
      let manifest = fetchImageManifest(spec, platform = self.platform)
      if not manifest.hasChalkLayer():
        raise newException(
          ValueError,
          "Last layer for " & $spec & " does not contain /chalk.json",
        )
      let lastLayer = manifest.layers[^1]
      return lastLayer.nameRef.layerGetFSFileStream(
        name   = "chalk.json",
        accept = manifest.mediaType,
      ).readAll()
    except:
      err = getCurrentExceptionMsg()
      trace("docker: could not extract chalk mark from registry: " & err)
      continue
  raise newException(ValueError, err)

proc extractMarkFromInToto(self: ChalkObj, json: JsonNode): string =
  let
    sigs      = json["signatures"]
    payload   = parseJson(json["payload"].getStr().decode())
    data      = payload["predicate"]["Data"].getStr().strip()
    predicate = parseJson(data)["predicate"]
    attrs     = predicate["attributes"].getElems()[0]
    rawMark   = attrs["evidence"].getStr()
  for subject in payload["subject"]:
    let digest = subject["digest"]["sha256"].getStr()
    if digest.extractDockerHash() != self.imageDigest.extractDockerHash():
      raise newException(
        ValueError,
        "In-Toto attestation subject does not match image digest: " &
        digest & " != " & self.imageDigest
      )
  self.collectedData["_SIGNATURES"] = sigs.nimJsonToBox()
  return rawMark

proc extractMarkFromSigStoreCosign(self: ChalkObj): string =
  var err = "no attestation found to extract chalk mark"
  for image in self.images.uniq():
    let
      spec   = image.withDigest(self.imageDigest).asRepoDigest()
      args   = @["download", "attestation", spec]
      cosign = getCosignLocation()
    info("cosign: downloading attestation for " & spec)
    trace("cosign " & args.join(" "))
    let
      allOut = runCmdGetEverything(cosign, args)
      res    = allOut.getStdout()
      code   = allout.getExit()
    if code != 0:
      err = allOut.getStdErr().splitLines()[0]
      continue
    let json = parseJson(res)
    return self.extractMarkFromInToto(json)
  raise newException(ValueError, err)

proc extractMarkFromSigStore(self: ChalkObj): string =
  var err = "no attestation found to extract chalk mark"
  for image in self.images.uniq():
    let
      tag  = "sha256-" & self.imageDigest & ".att"
      spec = image.withTag(tag).withDigest("")
    trace("docker: extract chalk mark from in-toto attestation for " & $spec)
    let manifest = fetchOnlyImageManifest(spec, fetchConfig = false)
    if manifest.kind != DockerManifestType.image:
      raise newException(
        ValueError,
        "Attestation should be image manifest but is instead " & $manifest.kind,
      )
    if len(manifest.layers) != 1:
      raise newException(
        ValueError,
        "Attestation manifest is expected to have at most one layer but " &
        $spec & " has " & $len(manifest.layers),
      )
    let
      layer     = manifest.layers[0]
      predicate = layer.annotations{"predicateType"}.getStr()
    if predicate != "https://cosign.sigstore.dev/attestation/v1":
      raise newException(
        ValueError,
        "Unsupported attestation predicate: " & predicate,
      )
    let data = layer.nameRef.layerGetJson(accept = layer.mediaType)
    return self.extractMarkFromInToto(data.json)
  raise newException(ValueError, err)

proc extractFrom(self: ChalkObj, mark: string, name: string) =
  if mark == "":
    raise newException(
      ValueError,
      "cannot extract chalk mark from empty string",
    )
  let extract = extractOneChalkJson(mark, name)
  self.collectedData.update(extract)
  self.extract    = extract
  self.cachedMark = mark
  self.marked     = true

proc extractImage*(self: ChalkObj) =
  if self.imageDigest != "":
    try:
      self.extractFrom(self.extractMarkFromSigStore(), self.getImageName())
      info("docker: " & self.getImageName() & ": chalk mark successfully extracted from in-toto attestation from registry")
      return
    except:
      trace("docker: " & self.getImageName() & ": could not extract chalk mark " &
            "via in-toto attestation due to: " & getCurrentExceptionMsg())

    try:
      self.extractFrom(self.extractMarkFromLayer(), self.getImageName())
      info("docker: " & self.getImageName() & ": chalk mark successfully extracted from layer from registry")
      return
    except:
      trace("docker: " & self.getImageName() & ": could not extract chalk mark " &
            "via layer in registry due to: " & getCurrentExceptionMsg())

  if self.canVerifyBySigStore():
    try:
      self.extractFrom(self.extractMarkFromSigStore(), self.getImageName())
      self.signed = true
      info("docker: " & self.getImageName() & ": chalk mark successfully extracted from attestation.")
      return
    except:
      self.noCosign = true
      trace("docker: " & self.getImageName & ": could not extract chalk mark " &
           "via attestation due to: " & getCurrentExceptionMsg())

  self.extractFrom(self.extractImageMark(), self.getImageName())
  info("docker: " & self.getImageName() & ": chalk mark successfuly extracted from image.")

proc extractContainer*(self: ChalkObj) =
  let mark = extractContainerMark(self.containerId)
  self.extractFrom(mark, self.containerId)
  info("docker: " & self.containerId & ": chalk mark successfully extracted from container.")
