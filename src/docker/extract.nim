##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## extract chalkmark json from images/containers into chalk object

import std/[algorithm, base64, enumerate]
import ".."/[attestation/utils, config, chalkjson, util]
import "."/[exe, inspect, ids]

proc hasChalkLayer(self: ChalkObj): bool =
  result = false
  let layers = inspectHistoryCommands(self.imageId)
  for layer in layers:
    let withoutComment = layer.split("#")[0].strip()
    if layer.startsWith("COPY ") and layer.endsWith(" /chalk.json"):
      return true

proc extractMarkFromStdOut(s: string): string =
  var raw = s
  while true:
    let ix = raw.find('{')
    if ix == -1:
      raise newException(ValueError, "No valid chalk mark json in stdout")
    raw = raw[ix .. ^1]
    if raw[1 .. ^1].strip().startswith("\"MAGIC\""):
      return raw

proc extractMarkFromLayer(imageId: string,
                          layerPath: string,
                          layerDescription: string): string =
  let layerId = layerPath.split(DirSep)[0]

  trace("Image " & imageId & ": extracting layer " & layerId)
  if runCmdExitCode("tar", @["-xf", "image.tar", layerPath]) != 0:
    raise newException(
      ValueError,
      "Image " & imageId & ": error extracting layer " & layerId & " from image tar archive",
    )

  trace("Image " & imageId & ": extracting chalk.json from layer " & layerId)
  if runCmdExitCode("tar", @["-xf", layerPath, "chalk.json"]) == 0:
    let mark = tryToLoadFile("chalk.json")
    if mark == "":
      raise newException(
        ValueError,
        "Image " & imageId & ": could not read chalk.json from layer " & layerId,
      )
    return mark
  else:
    raise newException(
      ValueError,
      "Image " & imageId & ": could not extract chalk.json from " &
      layerDescription & " layer " & layerId,
    )

proc extractImageMark(self: ChalkObj): string =
  trace("docker: extracting chalk mark from " & self.imageId)

  let catMark = runDockerGetEverything(@["run", "--rm", "--entrypoint=cat",
                                         self.imageId, "/chalk.json"])
  # cat is present and we found chalk mark
  if catMark.exitCode == 0:
    trace("docker: " & self.imageId & ": found chalk mark via cat")
    return catMark.stdOut

  # cat is present but no chalk mark found
  elif catMark.exitCode == 1:
    trace("docker: " & self.imageId & ": image has cat but is missing /chalk.json")
    raise newException(
      ValueError,
      self.imageId & ": is not chalked"
    )

  # any other exitcode like 127 probably means:
  # * cat was not found as entrypoint
  # * architecture of image doesnt match host
  # and so we manually inspect image layers via tar archive

  # no layer has /chalk.json so image is not chalked
  # so dont waste time saving image with as tar file
  if not self.hasChalkLayer():
    trace("docker: " & self.imageId & ": no layer copies /chalk.json")
    raise newException(
      ValueError,
      self.imageId & ": is not chalked"
    )

  let dir = getNewTempDir()
  withWorkingDir(dir):
    trace("docker: " & self.imageId & ": saving to tar file for extraction of metadata")
    if runDockerGetEverything(@["save", self.imageId, "-o", "image.tar"]).getExit() != 0:
      raise newException(
        ValueError,
        self.imageId & ": error extracting chalk mark",
      )
    if runCmdExitCode("tar", @["-xf", "image.tar", "manifest.json"]) != 0:
      raise newException(
        ValueError,
        self.imageId & ": could not extract manifest (no tar cmd?)",
      )

    trace("docker: " & self.imageId & ": extracting manifest.json from image tar archive")
    let manifest = tryToLoadFile("manifest.json")
    if manifest == "":
      raise newException(
        ValueError,
        self.imageId & ": could not extract manifest (permissions?)",
      )

    let
      manifestJson = manifest.parseJson()
      layers       = manifestJson.getElems()[0]["Layers"].getStrElems()

    # note we are checking layers in reverse order
    for i, layer in enumerate(layers.reversed()):
      try:
        return extractMarkFromLayer(self.imageId, layer, $i)
      except:
        discard

    raise newException(
      ValueError,
      self.imageId & ": no layer with /chalk.json was found"
    )

proc extractMarkFromSigStore(self: ChalkObj): string =
  let
    image  = self.image.withDigest(self.imageDigest).asRepoDigest()
    args   = @["download", "attestation", image]
    cosign = getCosignLocation()
  info("cosign: downloading attestation for " & image)
  trace("cosign " & args.join(" "))
  let
    allOut = runCmdGetEverything(cosign, args)
    res    = allOut.getStdout()
    code   = allout.getExit()
  if code != 0:
    raise newException(
      ValueError,
      allOut.getStdErr().splitLines()[0]
    )
  let
    json      = parseJson(res)
    signature = json["signatures"][0]
    payload   = parseJson(json["payload"].getStr().decode())
    data      = payload["predicate"]["Data"].getStr().strip()
    predicate = parseJson(data)["predicate"]
    attrs     = predicate["attributes"].getElems()[0]
    rawMark   = attrs["evidence"].getStr()
  self.collectedData["_SIGNATURE"] = signature.nimJsonToBox()
  return rawMark

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
  if self.canVerifyBySigStore():
    try:
      self.extractFrom(self.extractMarkFromSigStore(), $self.image)
      self.signed = true
      info("docker: " & $self.image & ": chalk mark successfully extracted from attestation.")
      return
    except:
      self.noCosign = true
      trace("docker: " & $self.image & ": could not extract chalk mark " &
           "via attestation due to: " & getCurrentExceptionMsg())

  self.extractFrom(self.extractImageMark(), $self.image)
  info("docker: " & $self.image & ": chalk mark successfuly extracted from image.")

proc extractContainer*(self: ChalkObj) =
  let
    cid      = self.containerId
    procInfo = runDockerGetEverything(@["cp", cid & ":/chalk.json", "-"])
    mark     = procInfo.getStdOut().extractMarkFromStdOut()
  if procInfo.getExit() != 0:
    let err = procInfo.getStdErr()
    if err.contains("No such container"):
      raise newException(
        ValueError,
        self.name & ": container shut down before mark extraction",
      )
    elif err.contains("Could not find the file"):
      raise newException(
        ValueError,
        self.name & ": container is unmarked.",
      )
    else:
      raise newException(
        ValueError,
        self.name & ": container mark not retrieved: " & err,
      )
  self.extractFrom(mark, cid)
  info("docker: " & cid & ": chalk mark successfully extracted from container.")
