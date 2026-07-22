##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin collects data from the AWS ECS Metadata IP.

import std/[
  os,
]
import pkg/[
  nimutils/awsclient,
]
import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/http,
  utils/json,
]

let
  cloudMetadataUrl3 = os.getEnv("ECS_CONTAINER_METADATA_URI")
  cloudMetadataUrl4 = os.getEnv("ECS_CONTAINER_METADATA_URI_V4")

# returns ecs metadata as a json blob
var
  ecsMetadata = ChalkDict()
  ecsUrl      = cloudMetadataUrl4
if ecsUrl == "":
  ecsUrl = cloudMetadataUrl3

proc clearCallback(self: Plugin) {.cdecl.} =
  ecsMetadata = ChalkDict()

proc requestECSMetadata(path: string): Box =
  let
    url  = ecsUrl & path
    resp =
      try:
        safeRequest(
          url               = url,
          retries           = 2,
          connectRetries    = 2,
          acceptStatusCodes = @[200..200],
        )
      except:
        let msg = getCurrentExceptionMsg()
        error("ecs: " & url & " request failed: " & msg)
        dumpExOnDebug()
        raise
  try:
    return parseJson(resp.body()).nimJsonToBox()
  except:
    let msg = getCurrentExceptionMsg()
    error("ecs: " & url & " didnt return valid json " & msg)
    dumpExOnDebug()
    raise newException(IOError, url & " returned invalid JSON: " & msg)

proc readECSMetadata*(): ChalkDict =
  # This can be called from outside if anything needs to query the JSON.
  # For now, we just return the whole blob.
  if len(ecsMetadata) == 0:
    if ecsUrl == "":
      trace("ecs: metadata env var is not defined: no AWS info available")
      return ecsMetadata
    ecsMetadata["container"] = requestECSMetadata("")
    try:
      ecsMetadata["task"] = requestECSMetadata("/task")
    except:
      let msg = getCurrentExceptionMsg()
      addFailedKey(
        "_OP_CLOUD_METADATA",
        code        = "ECS_TASK_METADATA_ERROR",
        error       = msg,
        description = "The ECS task metadata endpoint (" & ecsUrl & "/task) was unreachable or returned invalid data",
      )
    try:
      ecsMetadata["task/stats"] = requestECSMetadata("/task/stats")
    except:
      let msg = getCurrentExceptionMsg()
      addFailedKey(
        "_OP_CLOUD_METADATA",
        code        = "ECS_TASK_STATS_METADATA_ERROR",
        error       = msg,
        description = "The ECS task/stats metadata endpoint (" & ecsUrl & "/task/stats) was unreachable or returned invalid data",
      )
  return ecsMetadata

proc ecsGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()
  try:
    let data = readECSMetadata()
    if len(data) > 0:
      var cloudData = ChalkDict()
      cloudData["aws_ecs"] = pack(data)
      result.setIfNeeded("CLOUD_METADATA_WHEN_CHALKED", cloudData)
  except:
    let msg = getCurrentExceptionMsg()
    dumpExOnDebug()
    addFailedKey(
      "CLOUD_METADATA_WHEN_CHALKED",
      code        = "ECS_METADATA_ERROR",
      error       = msg,
      description = "The ECS container metadata endpoint (" & ecsUrl & ") was unreachable or returned invalid data",
    )

proc ecsGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                          ChalkDict {.cdecl.} =
  result = ChalkDict()
  try:
    let data = readECSMetadata()
    if len(data) > 0:
      var cloudData = ChalkDict()
      cloudData["aws_ecs"] = pack(data)
      result.setIfNeeded("_OP_CLOUD_METADATA",               cloudData)
      result.setIfNeeded("_OP_CLOUD_PROVIDER",               "aws")
      result.setIfNeeded("_OP_CLOUD_PROVIDER_SERVICE_TYPE",  "aws_ecs")
      let containerArnOpt = data.lookupByPath("container.ContainerARN")
      if containerArnOpt.isSome():
        let containerArn = parseArn($(containerArnOpt.get()))
        result.setIfNeeded("_OP_CLOUD_PROVIDER_ACCOUNT_INFO", containerArn.account)
        result.setIfNeeded("_OP_CLOUD_PROVIDER_REGION",       containerArn.region)
        result.setIfNeeded("_AWS_REGION",                     containerArn.region)
  except:
    let msg = getCurrentExceptionMsg()
    dumpExOnDebug()
    addFailedKey(
      "_OP_CLOUD_METADATA",
      code        = "ECS_METADATA_ERROR",
      error       = msg,
      description = "The ECS container metadata endpoint (" & ecsUrl & ") was unreachable or returned invalid data",
    )

proc loadAwsEcs*() =
  newPlugin("aws_ecs",
            clearCallback  = PluginClearCb(clearCallback),
            ctHostCallback = ChalkTimeHostCb(ecsGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(ecsGetRunTimeHostInfo))
