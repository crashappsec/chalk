##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk extract` command.

import "../docker"/[scan]
import ".."/[config, collect, reporting, plugins/codecDocker, plugin_api]

proc processDockerChalk(item: ChalkObj) =
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

proc coreExtractFiles(path: seq[string]) =
  var numExtracts = 0
  for item in artifacts(path):
    numExtracts += 1
  if not inSubscan() and numExtracts == 0 and getCommandName() == "extract":
    warn("No chalk marks extracted")

proc coreExtractImages() =
  var n      = 0
  let docker = getPluginByName("docker")
  for item in docker.scanAllImages():
    n += 1
    item.processDockerChalk()
  if n == 0:
    warn("No docker images found.")

proc coreExtractContainers() =
  var n      = 0
  let docker = getPluginByName("docker")
  for item in docker.scanAllContainers():
    n += 1
    item.processDockerChalk()
  if n == 0:
    warn("No docker containers found.")

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
