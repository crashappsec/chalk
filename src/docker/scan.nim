##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for scanning docker information into new chalk data-structures
##
## scan - create new chalk object and collect docker info into it

import ".."/[config]
import "."/[collect, inspect, extract]

proc scanImage*(codec: Plugin, item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = codec)
  try:
    chalk.collectImage(item)
  except:
    return none(ChalkObj)
  try:
    chalk.extractImage()
  except:
    warn("docker: could not extract chalk mark from image: " & getCurrentExceptionMsg())
    addUnmarked(item)
  return some(chalk)

proc scanImageOrContainer*(codec: Plugin, item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = codec)
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
    chalk.collectImage(image)
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

iterator scanAllContainers*(codec: Plugin): ChalkObj =
  for id in allContainerIDs():
    trace("docker: found container with ID = " & id)
    yield codec.scanImageOrContainer(id).get()

iterator scanAllImages*(codec: Plugin): ChalkObj =
  for id in allImageIDs():
    trace("docker: found image with ID = " & id)
    yield codec.scanImage(id).get()
