## This plugin collects data from the AWS ECS Metadata IP.
##
## :Author: Liming Luo (liming@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.
import os, tables, httpclient, json, options, nimutils, ../config, ../plugins


when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}
type AwsEcs = ref object of Plugin

var cloudMetadataUrl = os.getEnv("ECS_CONTAINER_METADATA_URI")

# returns ecs metadata as a json blob

var ecsMetadata: Option[JsonNode] = none(JsonNode)

proc readECSMetadata*(): Option[JsonNode] =
  # This can be called from outside if anything needs to query the JSON.
  # For now, we just return the whole blob.
  once:
    if cloudMetadataUrl == "":
        info("ecs: metadata env var is not defined: no AWS info available")
    else:
      var
        client = newHttpClient()
        resp   = client.get(cloudMetadataUrl)
      if resp == nil or resp.status != "200 OK":
        error("failed to fetch " & cloudMetadataUrl & "; response: " &
              resp.status)
      else:
        ecsMetadata = some(parseJson(resp.body()))

  return ecsMetadata


template reportECSData(key: string) =
  result      = ChalkDict()
  if readECSMetadata().isSome():
    result[key] = pack($(ecsMetadata.get()))

method getHostInfo*(self: AwsEcs, path: seq[string], ins: bool): ChalkDict =
  reportECSData("CLOUD_METADATA")

method getPostRunInfo*(self: AwsEcs, objs: seq[ChalkObj]): ChalkDict =
  reportECSData("_OP_CLOUD_METADATA")

registerPlugin("aws_ecs", AwsEcs())
