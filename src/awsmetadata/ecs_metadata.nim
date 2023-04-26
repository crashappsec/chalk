import os, std/httpclient, std/json, options
import logging

var logger = newConsoleLogger()
addHandler(logger)

var cloudMetadataUrl = os.getEnv("ECS_CONTAINER_METADATA_URI")

# returns ecs metadata as a json blob
proc ReadECSMetadata(): Option[JsonNode] =
    cloudMetadataUrl = ""
    if cloudMetadataUrl == "":
        error("ecs: metadata env var is not defined")
        return none(JsonNode)

    var client = newHttpClient()
    var resp = client.get(cloudMetadataUrl)
    if resp == nil or resp.status != "200 OK":
        error("failed to fetch ", cloudMetadataUrl, " response ", resp.status)
        return none(JsonNode)

    var body = resp.body()
    var output = parseJson(body)

    return some(output)
