import ../config, ../collect, ../reporting, ../plugins/codecDocker


template processDockerChalkList(chalkList: seq[ChalkObj]) =
  for item in chalkList:
    trace("Processing artifact: " & item.name)
    item.addToAllChalks()
    trace("Collecting artifact runtime info")
    item.collectRuntimeArtifactInfo()
    let mark = codecDocker.dockerExtractChalkMark(item)
    if mark == nil:
      info(item.name & ": Artifact is unchalked.")
    else:
      for k, v in mark:
        item.collectedData[k] = v
      item.extract = mark
      item.marked = true
      item.extractAndValidateSignature()
    clearErrorObject()

template coreExtractFiles(path: seq[string]) =
  var numExtracts = 0
  for item in artifacts(path):
    numExtracts += 1

  if numExtracts == 0 and getCommandName() == "extract":
    warn("No chalk marks extracted")

template coreExtractImages() =
  let
    docker = Codec(getPluginByName("docker"))
    images = docker.getImageChalks()

  if len(images) == 0:
    warn("No docker images found.")
  else:
    images.processDockerChalkList()

template coreExtractContainers() =
  let
    docker     = Codec(getPluginByName("docker"))
    containers = docker.getContainerChalks()

  if len(containers) == 0:
    warn("No containers found.")
  else:
    containers.processDockerChalkList()


proc runCmdExtract*(path: seq[string]) {.exportc,cdecl.} =
  setContextDirectories(path)
  initCollection()
  coreExtractFiles(path)
  doReporting()

proc runCmdExtractImages*() =
  initCollection()
  coreExtractImages()
  doReporting()

proc runCmdExtractContainers*() =
  initCollection()
  coreExtractContainers()
  doReporting()

proc runCmdExtractAll*(path: seq[string]) =
  setContextDirectories(path)
  initCollection()
  coreExtractFiles(path)
  coreExtractImages()
  coreExtractContainers()
  doReporting()
