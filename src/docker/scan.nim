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
import "."/[collect, inspect]

proc scanImage*(codec: Plugin, item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = codec,
                       extract = ChalkDict())
  try:
    chalk.collectImage(item)
  except:
    return none(ChalkObj)
  return some(chalk)

proc scanImageOrContainer*(codec: Plugin, item: string): Option[ChalkObj] =
  let chalk = newChalk(name    = item,
                       codec   = codec,
                       extract = ChalkDict())
  var image = item
  try:
    chalk.collectContainer(item)
    image = chalk.imageId
  except:
    discard
  try:
    chalk.collectImage(image)
  except:
    return none(ChalkObj)
  return some(chalk)

iterator scanAllContainers*(codec: Plugin): ChalkObj =
  for id in allContainerIDs():
    trace("docker: found container with ID = " & id)
    let chalk = newChalk(codec   = codec,
                         extract = ChalkDict())
    chalk.collectContainer(id)
    chalk.collectImage(chalk.imageId)
    yield chalk

iterator scanAllImages*(codec: Plugin): ChalkObj =
  for id in allImageIDs():
    trace("docker: found image with ID = " & id)
    let chalk = newChalk(codec   = codec,
                         extract = ChalkDict())
    chalk.collectImage(id)
    yield chalk
