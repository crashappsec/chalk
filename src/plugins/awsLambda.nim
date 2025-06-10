##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin collects data from the AWS Lambda env vars

import std/[
  os,
]
import pkg/[
  nimutils/stsclient,
]
import ".."/[
  plugin_api,
  run_management,
  types,
]

var lambdaMetadata = ChalkDict()

proc clearCallback(self: Plugin) {.cdecl.} =
  lambdaMetadata = ChalkDict()

proc collectLambdaMetadata(): ChalkDict =
  # This can be called from outside if anything needs to query the JSON.
  # For now, we just return the whole blob.
  if len(lambdaMetadata) == 0:
    let
      region          = os.getEnv("AWS_REGION", os.getEnv("AWS_DEFAULT_REGION"))
      functionName    = os.getEnv("AWS_LAMBDA_FUNCTION_NAME")
      functionVersion = os.getEnv("AWS_LAMBDA_FUNCTION_VERSION")
      logGroup        = os.getEnv("AWS_LAMBDA_LOG_GROUP_NAME")
      logStream       = os.getEnv("AWS_LAMBDA_LOG_STREAM_NAME")
      accessKey       = os.getEnv("AWS_ACCESS_KEY_ID")
      secretKey       = os.getEnv("AWS_SECRET_ACCESS_KEY")
      sessionToken    = os.getEnv("AWS_SESSION_TOKEN")

    if functionName == "" or functionVersion == "":
      trace("lambda: function env vars are not defined: no AWS info available")
      return lambdaMetadata

    # https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html
    lambdaMetadata.setIfNotEmpty("AWS_REGION", region)
    lambdaMetadata.setFromEnvVar("AWS_LAMBDA_FUNCTION_NAME")
    lambdaMetadata.setFromEnvVar("AWS_LAMBDA_FUNCTION_VERSION")
    lambdaMetadata.setFromEnvVar("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")
    lambdaMetadata.setFromEnvVar("AWS_LAMBDA_LOG_GROUP_NAME")
    lambdaMetadata.setFromEnvVar("AWS_LAMBDA_LOG_STREAM_NAME")
    lambdaMetadata.setFromEnvVar("AWS_EXECUTION_ENV")
    lambdaMetadata.setFromEnvVar("LAMBDA_TASK_ROOT")
    lambdaMetadata.setFromEnvVar("LAMBDA_RUNTIME_DIR")

    if accessKey != "" and secretKey != "":
      try:
        var
          client   = newStsClient((accessKey, secretKey, sessionToken), region)
          roleArn: Arn
        let
          lambdaResource  = "function:" & functionName
          versionResource = lambdaResource & ":" & functionVersion
          streamResource  = "log-group:" & logGroup & ":log-stream:" & logStream
          identity        = client.getCallerIdentity()
          credsArn        = identity.arn
        if credsArn.resource.startsWith("assumed-role"):
          let roleName    = credsArn.resource.split("/")[1]
          roleArn         = credsArn.with(service="iam", resource="role/" & roleName)
        else:
          # creds are already fully formed IAM user
          roleArn         = credsArn
        let
          # roles dont have region as they are global so add region back
          lambdaArn       = roleArn.with(resource=lambdaResource, service="lambda", region=region)
          versionArn      = lambdaArn.with(resource=versionResource)
          streamArn       = lambdaArn.with(resource=streamResource, service="logs")

        lambdaMetadata.setIfNotEmpty("AWS_ACCOUNT_ID",              roleArn.account)
        lambdaMetadata.setIfNotEmpty("AWS_ROLE_ARN",                $(roleArn))
        lambdaMetadata.setIfNotEmpty("AWS_LAMBDA_FUNCTION_ARN",     $(lambdaArn))
        lambdaMetadata.setIfNotEmpty("AWS_LAMBDA_VERSION_ARN",      $(versionArn))
        if logGroup != "" and logStream != "":
          lambdaMetadata.setIfNotEmpty("AWS_LAMBDA_LOG_STREAM_ARN", $(streamArn))

      except:
        error("lambda: could not fetch information about AWS account due to: " & getCurrentExceptionMsg())
    else:
      warn("lambda: AWS credentials env vars are missing")

  return lambdaMetadata

proc lambdaCallback*(self: Plugin, objs: seq[ChalkObj]):
                            ChalkDict {.cdecl.} =
  result = ChalkDict()
  var data = collectLambdaMetadata()
  if len(data) != 0:
    var cloudData = ChalkDict()
    cloudData["aws_lambda"] = pack(data)
    result.setIfNeeded("_OP_CLOUD_METADATA",              cloudData)
    result.setIfNeeded("_OP_CLOUD_PROVIDER",              "aws")
    result.setIfNeeded("_OP_CLOUD_PROVIDER_SERVICE_TYPE", "aws_lambda")
    result.setIfNeeded("_OP_CLOUD_PROVIDER_ACCOUNT_INFO", data.lookupByPath("AWS_ACCOUNT_ID"))
    result.setIfNeeded("_OP_CLOUD_PROVIDER_REGION",       data.lookupByPath("AWS_REGION"))
    result.setIfNeeded("_AWS_REGION",                     data.lookupByPath("AWS_REGION"))

proc loadAwsLambda*() =
  newPlugin("aws_lambda",
            clearCallback  = PluginClearCb(clearCallback),
            rtHostCallback = RunTimeHostCb(lambdaCallback))
