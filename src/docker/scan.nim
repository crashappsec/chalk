##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for scanning docker information into new chalk data-structures
##
## scan - create new chalk object and collect docker info into it

import ".."/[
  plugin_api,
  run_management,
  types,
]
import "."/[
  collect,
  extract,
  ids,
  inspect,
]

proc scanLocalImage*(item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = getPluginByName("docker"))
  chalk.withErrorContext():
    try:
      chalk.collectLocalImage(item)
    except:
      return none(ChalkObj)
    try:
      chalk.extractImage()
    except:
      warn("docker: could not extract chalk mark from image: " & getCurrentExceptionMsg())
      addUnmarked(item)
    return some(chalk)

proc scanImage*(item: DockerImage, platform: DockerPlatform): Option[ChalkObj] =
  if $item == "scratch":
    return none(ChalkObj)
  var chalk = newChalk(name     = $item,
                       codec    = getPluginByName("docker"),
                       platform = platform)
  chalk.withErrorContext():
    try:
      chalk.collectImage(item)
    except:
      return none(ChalkObj)
    # if we already collected the same image before, return the same pointer
    # so that we do not duplicate collected artifacts
    for artifact in getAllChalks() & getAllArtifacts():
      if artifact.collectedData.getOrDefault("_IMAGE_ID", pack("")) == chalk.collectedData["_IMAGE_ID"]:
        artifact.collectedData.merge(chalk.collectedData)
        chalk = artifact
  chalk.withErrorContext():
    try:
      chalk.extractImage()
    except:
      warn("docker: could not extract chalk mark from image: " & getCurrentExceptionMsg())
      addUnmarked($item)
    return some(chalk)

proc scanLocalImageOrContainer*(item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = getPluginByName("docker"))
  chalk.withErrorContext():
    var image = item
    try:
      chalk.collectContainer(image)
      image = chalk.imageId
      try:
        chalk.extractContainer()
      except:
        warn("docker: could not extract chalk mark from container " & item & ": " & getCurrentExceptionMsg())
        # will reattempt to extract from image
        # there are valid reason why container might not have chalk mark
        # such as it was a virtual insert
    except:
      trace("docker: " & getCurrentExceptionMsg())
    try:
      chalk.collectLocalImage(image)
      try:
        chalk.extractImage()
      except:
        warn("docker: could not extract chalk mark from image " & image & ": " & getCurrentExceptionMsg())
    except:
      trace("docker: " & getCurrentExceptionMsg())
      return none(ChalkObj)
    if not chalk.isChalked():
      addUnmarked(item)
    return some(chalk)

iterator scanAllContainers*(): ChalkObj =
  for id in allContainerIDs():
    trace("docker: found container with ID = " & id)
    yield scanLocalImageOrContainer(id).get()

iterator scanAllImages*(): ChalkObj =
  for id in allImageIDs():
    trace("docker: found image with ID = " & id)
    yield scanLocalImage(id).get()
