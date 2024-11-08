##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin collects data from the AWS ECS Metadata IP.

import std/httpclient
import pkg/[nimutils/awsclient]
import ".."/[config, chalkjson, plugin_api]

let
  cloudMetadataUrl3 = os.getEnv("ECS_CONTAINER_METADATA_URI")
  cloudMetadataUrl4 = os.getEnv("ECS_CONTAINER_METADATA_URI_V4")

# returns ecs metadata as a json blob
var
  ecsMetadata = ChalkDict()
  ecsUrl = cloudMetadataUrl4
if ecsUrl == "":
  ecsUrl = cloudMetadataUrl3

proc clearCallback(self: Plugin) {.cdecl.} =
  ecsMetadata = ChalkDict()

proc requestECSMetadata(path: string): Option[Box] =
  let url = ecsUrl & path
  var body = ""
  try:
    var
      resp   = safeRequest(url, retries=2, connectRetries=2)
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
  if len(ecsMetadata) == 0:
    if ecsUrl == "":
      trace("ecs: metadata env var is not defined: no AWS info available")
      return ecsMetadata

    let container = requestECSMetadata("")
    if container.isNone():
      return ecsMetadata

    ecsMetadata["container"] = container.get()

    let task = requestECSMetadata("/task")
    if task.isSome():
      ecsMetadata["task"] = task.get()

    let stats = requestECSMetadata("/task/stats")
    if stats.isSome():
      ecsMetadata["task/stats"] = stats.get()

  return ecsMetadata

proc ecsGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  let data = readECSMetadata()
  result = ChalkDict()
  if len(data) > 0:
    var cloudData = ChalkDict()
    cloudData["aws_ecs"] = pack(data)
    result.setIfNeeded("CLOUD_METADATA_WHEN_CHALKED", cloudData)

proc ecsGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                          ChalkDict {.cdecl.} =
  let data = readECSMetadata()
  result = ChalkDict()
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

proc loadAwsEcs*() =
  newPlugin("aws_ecs",
            clearCallback  = PluginClearCb(clearCallback),
            ctHostCallback = ChalkTimeHostCb(ecsGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(ecsGetRunTimeHostInfo))
