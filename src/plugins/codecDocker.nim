##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "../docker"/[base, exe, collect]
import ".."/[config, chalkjson, attestation_api, plugin_api, util]

const markLocation = "/chalk.json"

proc dockerGetChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  if chalk.extract != nil and "CHALK_ID" in chalk.extract:
    return unpack[string](chalk.extract["CHALK_ID"])
  return dockerGenerateChalkId()

proc extractChalkMarkFromLayer(imageId: string,
                               layerPath: string,
                               layerDescription: string): Option[(string, ChalkDict)] =
  let layerId = layerPath.split(DirSep)[0]

  trace("Image " & imageId & ": extracting layer " & layerId)
  if runCmdExitCode("tar", @["-xf", "image.tar", layerPath]) != 0:
    error("Image " & imageId & ": error extracting layer " & layerId & " from image tar archive")
    return none((string, ChalkDict))

  trace("Image " & imageId & ": extracting chalk.json from layer " & layerId)
  if runCmdExitCode("tar", @["-xf", layerPath, "chalk.json"]) == 0:
    let cachedMark = tryToLoadFile("chalk.json")
    if cachedMark == "":
      error("Image " & imageId & ": could not read chalk.json from layer " & layerId)
    else:
      return some((cachedMark, extractOneChalkjson(cachedMark, imageId)))
  else:
    warn("Image " & imageId & ": could not extract chalk.json from " &
         layerDescription & " layer " & layerId)

  return none((string, ChalkDict))

proc extractImageMark(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)

  let
    imageId = chalk.imageId
    dir     = getNewTempDir()

  let catMark = runDockerGetEverything(@["run", "--rm", "--entrypoint=cat",
                                         imageId, markLocation])

  # cat is present and we found chalk mark
  if catMark.exitCode == 0:
    chalk.cachedMark = catMark.stdOut
    result           = extractOneChalkjson(catMark.stdOut, imageId)
    return

  # cat is present but no chalk mark found
  elif catMark.exitCode == 1:
    return

  # any other exitcode like 127 probably means:
  # * cat was not found as entrypoint
  # * architecture of image doesnt match host
  # and so we manually inspect image layers via tar archive

  try:
    withWorkingDir(dir):

      trace("Image " & imageId & ": Saving to tar file for extraction of metadata")
      let saving = runDockerGetEverything(@["save", imageId, "-o", "image.tar"])
      if saving.getExit() != 0:
        error("Image " & imageId & ": error extracting chalk mark")
        return

      if runCmdExitCode("tar", @["-xf", "image.tar", "manifest.json"]) != 0:
        error("Image " & imageId & ": could not extract manifest (no tar cmd?)")
        return

      trace("Image " & imageId & ": Extracting manifest.json from image tar archive")
      let manifest = tryToLoadFile("manifest.json")
      if manifest == "":
        error("Image " & imageId & ": could not extract manifest (permissions?)")
        return

      let
        manifestJson = manifest.parseJson()
        layers       = manifestJson.getElems()[0]["Layers"]
        topLayerMark = extractChalkMarkFromLayer(imageId, layers[^1].getStr(), "top")

      if topLayerMark.isSome():
        let (cachedMark, mark) = topLayerMark.get()
        chalk.cachedMark       = cachedMark
        result                 = mark
        return

      else:
        if not get[bool](chalkConfig, "extract.search_base_layers_for_marks"):
          return

        # We're only going to go deeper if there's no chalk mark found.
        var n = len(layers) - 1
        while n != 0:
          n = n - 1
          try:
            let layerMark = extractChalkMarkFromLayer(imageId, layers[n].getStr(), $(n))
            if layerMark.isNone():
              continue
            let
              (_, mark) = layerMark.get()
              cid       = mark["CHALK_ID"]
              mdid      = mark["METADATA_ID"]

            info("In layer " & $(n) & " (of " & $(len(layers)) & "), found " &
              "Chalk mark reporting CHALK_ID = " & $(cid) &
              " and METADATA_ID = " & $(mdid))
            chalk.collectedData["_FOUND_BASE_MARK"] = pack(@[cid, mdid])
            return
          except:
            continue

  except:
    dumpExOnDebug()
    trace(imageId & ": Could not complete mark extraction")

proc extractMarkFromStdin(s: string): string =
  var raw = s

  while true:
    let ix = raw.find('{')
    if ix == -1:
      return ""
    raw = raw[ix .. ^1]
    if raw[1 .. ^1].strip().startswith("\"MAGIC\""):
      return raw

proc extractContainerMark(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)
  let
    cid = chalk.containerId

  try:
    let
      procInfo = runDockerGetEverything(@["cp", cid & ":" & markLocation, "-"])
      mark     = procInfo.getStdOut().extractMarkFromStdin()

    if procInfo.getExit() != 0:
      let err = procInfo.getStdErr()
      if err.contains("No such container"):
        error(chalk.name & ": container shut down before mark extraction")
      elif err.contains("Could not find the file"):
        warn(chalk.name & ": container is unmarked.")
      else:
        warn(chalk.name & ": container mark not retrieved: " & err)
      return
    result = extractOneChalkJson(newStringStream(mark), cid)
  except:
    dumpExOnDebug()
    error(chalk.name & ": got error when extracting from container.")

proc dockerGetRunTimeArtifactInfo(self: Plugin, chalk: ChalkObj, ins: bool):
                                 ChalkDict {.exportc, cdecl.} =
  result = ChalkDict()
  # If a container name / id was passed, it got inspected during scan,
  # but images did not.
  if ResourceImage in chalk.resourceType:
    chalk.collectImage()

proc dockerExtractChalkMark*(chalk: ChalkObj): ChalkDict {.exportc, cdecl.} =
  if chalk.repo != "" and chalk.imageDigest != "":
    result = chalk.extractAttestationMark()

  if result != nil:
    info(chalk.name & ": Chalk mark successfully extracted from attestation.")
    chalk.extract = result
    chalk.signed = true
    return

  result = chalk.extractImageMark()
  if result != nil:
    info(chalk.name & ": Chalk mark extracted from base image.")
    return
  if chalk.containerId != "":
    result = chalk.extractContainerMark()
    if result != nil:
      info(chalk.name & ": Chalk mark extracted from running container")
      return

  warn(chalk.name & ": No chalk mark extracted.")
  addUnmarked(chalk.name)

proc loadCodecDocker*() =
  # cant use getDockerExePath as that uses codecs to ignore chalk
  # wrappings hence we just check if anything docker is on PATH here
  let enabled = nimutils.findExePath("docker") != ""
  if not enabled:
    warn("Disabling docker codec as docker command is not available")
  newCodec("docker",
           rtArtCallback = RunTimeArtifactCb(dockerGetRunTimeArtifactInfo),
           getChalkId    = ChalkIdCb(dockerGetChalkId),
           enabled       = enabled)
