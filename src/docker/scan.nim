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

proc scanImage(chalk:         ChalkObj,
               name:          string,
               image:         DockerImage,
               fromManifest = true,
               ): Option[ChalkObj] =
  if name == "scratch":
    return none(ChalkObj)
  var chalk = chalk
  chalk.withErrorContext():
    try:
      chalk.collectImage(
        image,
        collectFromManifest  = fromManifest,
        ifManySystemPlatform = true,
      )
    except:
      trace("docker: " & getCurrentExceptionMsg())
      return none(ChalkObj)
    if ResourceContainer notin chalk.resourceType:
      # if we already collected the same image before, return the same pointer
      # so that we do not duplicate collected artifacts
      for artifact in getAllChalks() & getAllArtifacts():
        if artifact.cachedEndingHash != "" and artifact.cachedEndingHash == chalk.cachedEndingHash:
          artifact.collectedData.merge(chalk.collectedData)
          chalk = artifact
    try:
      chalk.extractImage()
    except:
      warn("docker: could not extract chalk mark from image: " & getCurrentExceptionMsg())
  if not chalk.isChalked():
    addUnmarked(name)
  return some(chalk)

proc scanImage*(name:          string | DockerImage,
                platform     = DockerPlatform(nil),
                fromManifest = true,
                ): Option[ChalkObj] =
  let
    image =
      when name is string:
        parseImage(name, defaultTag = "")
      else:
        name
    name = $name
  var chalk = newChalk(name     = name,
                       codec    = getPluginByName("docker"),
                       platform = platform)
  return chalk.scanImage(name, image)

proc scanImageOrContainer*(name: string): Option[ChalkObj] =
  var
    chalk        = newChalk(name    = name,
                            codec   = getPluginByName("docker"))
    image        = parseImage(name, defaultTag = "")
    fromManifest = true
  chalk.withErrorContext():
    try:
      chalk.collectContainer(name)
      image = parseImage(chalk.imageId, defaultTag = "")
      fromManifest = false
      try:
        chalk.extractContainer()
      except:
        # will reattempt to extract from image
        # there are valid reason why container might not have chalk mark
        # such as it was a virtual insert
        warn("docker: could not extract chalk mark from container " & name &
             ": " & getCurrentExceptionMsg())
    except:
      trace("docker: " & getCurrentExceptionMsg())
  return chalk.scanImage(name, image, fromManifest = fromManifest)

iterator scanAllContainers*(): ChalkObj =
  for id in allContainerIDs():
    trace("docker: found container with ID = " & id)
    yield scanImageOrContainer(id).get()

iterator scanAllImages*(): ChalkObj =
  for id in allImageIDs():
    trace("docker: found image with ID = " & id)
    yield scanImage(id).get()
