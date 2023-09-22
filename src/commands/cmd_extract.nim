##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk extract` command.

import ../config, ../collect, ../reporting, ../plugins/codecDocker,
       ../plugin_api, ../docker_base

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

  if not inSubscan() and numExtracts == 0 and getCommandName() == "extract":
    warn("No chalk marks extracted")

template coreExtractImages() =
  let
    docker = getPluginByName("docker")
    images = docker.getImageChalks()

  if len(images) == 0:
    warn("No docker images found.")
  else:
    images.processDockerChalkList()

template coreExtractContainers() =
  let
    docker     = getPluginByName("docker")
    containers = docker.getContainerChalks()

  if len(containers) == 0:
    warn("No containers found.")
  else:
    containers.processDockerChalkList()


proc runCmdExtract*(path: seq[string]) {.exportc,cdecl.} =
  setDockerExeLocation()
  setContextDirectories(path)
  initCollection()
  coreExtractFiles(path)
  doReporting()

proc runCmdExtractImages*() =
  setDockerExeLocation()
  initCollection()
  coreExtractImages()
  doReporting()

proc runCmdExtractContainers*() =
  setDockerExeLocation()
  initCollection()
  coreExtractContainers()
  doReporting()

proc runCmdExtractAll*(path: seq[string]) =
  setDockerExeLocation()
  setContextDirectories(path)
  initCollection()
  coreExtractFiles(path)
  coreExtractImages()
  coreExtractContainers()
  doReporting()
