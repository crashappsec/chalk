##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin collects data from the AWS ECS Metadata IP.

import httpclient, ../config, ../chalkjson, ../plugin_api

let
  cloudMetadataUrl3 = os.getEnv("ECS_CONTAINER_METADATA_URI")
  cloudMetadataUrl4 = os.getEnv("ECS_CONTAINER_METADATA_URI_V4")

# returns ecs metadata as a json blob
var
  ecsMetadata: ChalkDict = ChalkDict()
  ecsUrl = cloudMetadataUrl4
if ecsUrl == "":
  ecsUrl = cloudMetadataUrl3

proc requestECSMetadata(path: string): Option[Box] =
  let url = ecsUrl & path
  var body = ""
  info(url)
  try:
    var
      client = newHttpClient()
      resp   = client.safeRequest(url)
    if resp.code != Http200:
      error("ecs: " & url & " returned " & resp.status)
      return none(Box)
    body = resp.body()
  except:
    error("ecs: " & url & " request failed with " & getCurrentExceptionMsg())
    return none(Box)
  try:
    let parsed = parseJson(body)
    return some(parsed.nimJsonToBox())
  except:
    error("ecs: " & url & " didnt return valid json " & getCurrentExceptionMsg())
    return none(Box)

proc readECSMetadata*(): ChalkDict =
  # This can be called from outside if anything needs to query the JSON.
  # For now, we just return the whole blob.
  once:
    if ecsUrl == "":
      trace("ecs: metadata env var is not defined: no AWS info available")
      return ecsMetadata

    let container = requestECSMetadata("")
    if container.isNone():
      return ecsMetadata

    var ecs = ChalkDict()
    ecs["container"] = container.get()

    let task = requestECSMetadata("/task")
    if task.isSome():
      ecs["task"] = task.get()

    let stats = requestECSMetadata("/task/stats")
    if stats.isSome():
      ecs["task/stats"] = stats.get()

    ecsMetadata["aws_ecs"] = pack(ecs)

  return ecsMetadata

template reportECSData(key: string) =
  result = ChalkDict()
  result.setIfNeeded(key, readECSMetadata())

proc ecsGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  reportECSData("CLOUD_METADATA_WHEN_CHALKED")

proc ecsGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                          ChalkDict {.cdecl.} =
  reportECSData("_OP_CLOUD_METADATA")

proc loadEcs*() =
  newPlugin("aws_ecs",
            ctHostCallback = ChalkTimeHostCb(ecsGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(ecsGetRunTimeHostInfo))
