##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## extract chalkmark json from images/containers into chalk object

import ".."/[
  attestation/utils,
  chalkjson,
  run_management,
  types,
  utils/files,
  utils/json,
]
import "."/[
  exe,
  ids,
  inspect,
  manifest,
  registry,
]

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
          containerId & ": " & cpCmd.stderr)
    if "No such container" in cpCmd.stderr:
      raise newException(
        ValueError,
        containerId & ": container shut down before mark extraction",
      )
    elif "Could not find the file" in cpCmd.stderr:
      raise newException(
        ValueError,
        containerId & ": container is unmarked.",
      )
    else:
      raise newException(
        ValueError,
        containerId & ": container mark not retrieved: " & cpCmd.stderr,
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
    containerId = createCmd.stdout.strip()
  if createCmd.exitCode != 0:
    trace("docker: " & self.imageId & ": could not create container to extract /chalk.json: " &
          createCmd.stderr)
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
  for image in self.repos.manifests:
    trace("docker: extract chalk mark from registry for " & $image)
    try:
      let manifest = fetchImageManifest(image, platform = self.platform)
      if not manifest.hasChalkLayer():
        raise newException(
          ValueError,
          "Last layer for " & $image & " does not contain /chalk.json",
        )
      let lastLayer = manifest.layers[^1]
      return lastLayer.asImage().layerGetFileString(
        name   = "chalk.json",
        accept = manifest.mediaType,
      )
    except:
      err = getCurrentExceptionMsg()
      trace("docker: could not extract chalk mark from registry: " & err)
      continue
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
  if len(self.repos) > 0:
    for image in self.repos.manifests:
      for (dsse, mark) in image.fetchDsseInTotoMark():
        try:
          self.extractFrom(mark, self.getImageName())
          self.signed = true
          self.collectedData.setIfNotEmpty("_SIGNATURES", %(@[dsse]))
          info("docker: " & self.getImageName() & ": chalk mark successfully extracted from in-toto attestation from registry")
          return
        except:
          trace("docker: " & self.getImageName() & ": could not extract chalk mark " &
                "via in-toto attestation due to: " & getCurrentExceptionMsg())

  if len(self.repos) > 0:
    try:
      self.extractFrom(self.extractMarkFromLayer(), self.getImageName())
      info("docker: " & self.getImageName() & ": chalk mark successfully extracted from layer from registry")
      return
    except:
      trace("docker: " & self.getImageName() & ": could not extract chalk mark " &
            "via layer in registry due to: " & getCurrentExceptionMsg())

  self.extractFrom(self.extractImageMark(), self.getImageName())
  info("docker: " & self.getImageName() & ": chalk mark successfuly extracted from image.")

proc extractContainer*(self: ChalkObj) =
  let mark = extractContainerMark(self.containerId)
  self.extractFrom(mark, self.containerId)
  info("docker: " & self.containerId & ": chalk mark successfully extracted from container.")
