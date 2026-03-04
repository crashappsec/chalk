##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from an
## Azure DevOps Pipelines CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getAzureDevopsMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables
  let
    TF_BUILD                     = getEnv("TF_BUILD")
    BUILD_BUILDID                = getEnv("BUILD_BUILDID")
    BUILD_BUILDNUMBER            = getEnv("BUILD_BUILDNUMBER")
    BUILD_BUILDURI               = getEnv("BUILD_BUILDURI")
    BUILD_SOURCEVERSION          = getEnv("BUILD_SOURCEVERSION")
    BUILD_SOURCEBRANCH           = getEnv("BUILD_SOURCEBRANCH")
    BUILD_REPOSITORY_URI         = getEnv("BUILD_REPOSITORY_URI")
    BUILD_REPOSITORY_NAME        = getEnv("BUILD_REPOSITORY_NAME")
    BUILD_REPOSITORY_ID          = getEnv("BUILD_REPOSITORY_ID")
    BUILD_DEFINITIONNAME         = getEnv("BUILD_DEFINITIONNAME")
    BUILD_REASON                 = getEnv("BUILD_REASON")
    BUILD_REQUESTEDFOR           = getEnv("BUILD_REQUESTEDFOR")
    SYSTEM_TEAMPROJECT           = getEnv("SYSTEM_TEAMPROJECT")
    SYSTEM_TEAMPROJECTID         = getEnv("SYSTEM_TEAMPROJECTID")
    SYSTEM_TEAMFOUNDATIONCOLLURI = getEnv("SYSTEM_TEAMFOUNDATIONCOLLECTIONURI")
    SYSTEM_JOBID                 = getEnv("SYSTEM_JOBID")
    SYSTEM_DEFINITIONID          = getEnv("SYSTEM_DEFINITIONID")

  # probably not running in Azure DevOps Pipelines
  if TF_BUILD == "" and BUILD_BUILDID == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              SYSTEM_JOBID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       BUILD_SOURCEVERSION)
  result.setIfNeeded(prefix & "BUILD_API_URI",         SYSTEM_TEAMFOUNDATIONCOLLURI)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       BUILD_REPOSITORY_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", SYSTEM_TEAMPROJECTID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",      BUILD_REPOSITORY_URI)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   BUILD_DEFINITIONNAME)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   SYSTEM_DEFINITIONID)
  result.setIfNeeded(prefix & "BUILD_REF",             BUILD_SOURCEBRANCH)
  result.setIfNeeded(prefix & "BUILD_TRIGGER",         BUILD_REASON)

  # Construct BUILD_URI from components
  if SYSTEM_TEAMFOUNDATIONCOLLURI != "" and SYSTEM_TEAMPROJECT != "" and BUILD_BUILDID != "":
    result.setIfNeeded(prefix & "BUILD_URI",
      SYSTEM_TEAMFOUNDATIONCOLLURI.strip(leading = false, chars = {'/'}) &
      "/" & SYSTEM_TEAMPROJECT & "/_build/results?buildId=" & BUILD_BUILDID)

  if BUILD_REQUESTEDFOR != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[BUILD_REQUESTEDFOR])

proc azureDevopsGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getAzureDevopsMetadata()

proc azureDevopsGetRunTimeHostInfo(self: Plugin,
                                    chalks: seq[ChalkObj],
                                    ): ChalkDict {.cdecl.} =
  return self.getAzureDevopsMetadata(prefix = "_")

proc loadCiAzureDevops*() =
  newPlugin("ci_azure_devops",
            ctHostCallback = ChalkTimeHostCb(azureDevopsGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(azureDevopsGetRunTimeHostInfo))
