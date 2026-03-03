##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## CircleCI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getCircleciMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://circleci.com/docs/variables/#built-in-environment-variables
  let
    CIRCLECI                   = getEnv("CIRCLECI")
    CIRCLE_BUILD_NUM           = getEnv("CIRCLE_BUILD_NUM")
    CIRCLE_BUILD_URL           = getEnv("CIRCLE_BUILD_URL")
    CIRCLE_SHA1                = getEnv("CIRCLE_SHA1")
    CIRCLE_BRANCH              = getEnv("CIRCLE_BRANCH")
    CIRCLE_TAG                 = getEnv("CIRCLE_TAG")
    CIRCLE_JOB                 = getEnv("CIRCLE_JOB")
    CIRCLE_WORKFLOW_ID         = getEnv("CIRCLE_WORKFLOW_ID")
    CIRCLE_WORKFLOW_JOB_ID     = getEnv("CIRCLE_WORKFLOW_JOB_ID")
    CIRCLE_PIPELINE_ID         = getEnv("CIRCLE_PIPELINE_ID")
    CIRCLE_PROJECT_REPONAME    = getEnv("CIRCLE_PROJECT_REPONAME")
    CIRCLE_PROJECT_USERNAME    = getEnv("CIRCLE_PROJECT_USERNAME")
    CIRCLE_PROJECT_ID          = getEnv("CIRCLE_PROJECT_ID")
    CIRCLE_ORGANIZATION_ID     = getEnv("CIRCLE_ORGANIZATION_ID")
    CIRCLE_REPOSITORY_URL      = getEnv("CIRCLE_REPOSITORY_URL")
    CIRCLE_USERNAME            = getEnv("CIRCLE_USERNAME")

  # probably not running in CircleCI
  if CIRCLECI == "" and CIRCLE_BUILD_NUM == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              CIRCLE_WORKFLOW_JOB_ID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       CIRCLE_SHA1)
  result.setIfNeeded(prefix & "BUILD_URI",             CIRCLE_BUILD_URL)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       CIRCLE_PROJECT_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", CIRCLE_ORGANIZATION_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",      CIRCLE_REPOSITORY_URL)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   CIRCLE_WORKFLOW_ID)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   CIRCLE_JOB)

  # Construct BUILD_REF to match GitHub's refs/tags/ or refs/heads/ convention
  if CIRCLE_TAG != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/tags/" & CIRCLE_TAG)
  elif CIRCLE_BRANCH != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/heads/" & CIRCLE_BRANCH)

  if CIRCLE_USERNAME != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[CIRCLE_USERNAME])

proc circleciGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getCircleciMetadata()

proc circleciGetRunTimeHostInfo(self: Plugin,
                                chalks: seq[ChalkObj],
                                ): ChalkDict {.cdecl.} =
  return self.getCircleciMetadata(prefix = "_")

proc loadCiCircleci*() =
  newPlugin("ci_circleci",
            ctHostCallback = ChalkTimeHostCb(circleciGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(circleciGetRunTimeHostInfo))
