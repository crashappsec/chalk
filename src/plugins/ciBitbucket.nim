##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Bitbucket Pipelines CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getBitbucketMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/
  let
    BITBUCKET_BUILD_NUMBER    = getEnv("BITBUCKET_BUILD_NUMBER")
    BITBUCKET_COMMIT          = getEnv("BITBUCKET_COMMIT")
    BITBUCKET_BRANCH          = getEnv("BITBUCKET_BRANCH")
    BITBUCKET_TAG             = getEnv("BITBUCKET_TAG")
    BITBUCKET_REPO_SLUG       = getEnv("BITBUCKET_REPO_SLUG")
    BITBUCKET_REPO_UUID       = getEnv("BITBUCKET_REPO_UUID")
    BITBUCKET_REPO_FULL_NAME  = getEnv("BITBUCKET_REPO_FULL_NAME")
    BITBUCKET_WORKSPACE       = getEnv("BITBUCKET_WORKSPACE")
    BITBUCKET_PIPELINE_UUID   = getEnv("BITBUCKET_PIPELINE_UUID")
    BITBUCKET_STEP_UUID       = getEnv("BITBUCKET_STEP_UUID")
    BITBUCKET_PR_ID           = getEnv("BITBUCKET_PR_ID")
    BITBUCKET_GIT_HTTP_ORIGIN = getEnv("BITBUCKET_GIT_HTTP_ORIGIN")

  # probably not running in Bitbucket Pipelines
  if BITBUCKET_BUILD_NUMBER == "" and BITBUCKET_PIPELINE_UUID == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              BITBUCKET_STEP_UUID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       BITBUCKET_COMMIT)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       BITBUCKET_REPO_UUID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", BITBUCKET_WORKSPACE)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",      BITBUCKET_GIT_HTTP_ORIGIN)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   BITBUCKET_REPO_FULL_NAME)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   BITBUCKET_PIPELINE_UUID)

  # Construct BUILD_URI from BITBUCKET_GIT_HTTP_ORIGIN (e.g. https://bitbucket.org/workspace/repo)
  if BITBUCKET_GIT_HTTP_ORIGIN != "" and BITBUCKET_BUILD_NUMBER != "":
    result.setIfNeeded(prefix & "BUILD_URI",
      BITBUCKET_GIT_HTTP_ORIGIN.strip(leading = false, chars = {'/'}) &
      "/pipelines/results/" & BITBUCKET_BUILD_NUMBER)

  if BITBUCKET_TAG != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/tags/" & BITBUCKET_TAG)
  elif BITBUCKET_BRANCH != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/heads/" & BITBUCKET_BRANCH)

  if BITBUCKET_PR_ID != "":
    result.setIfNeeded(prefix & "BUILD_TRIGGER", "pullrequest")
  elif BITBUCKET_TAG != "":
    result.setIfNeeded(prefix & "BUILD_TRIGGER", "tag")
  else:
    result.setIfNeeded(prefix & "BUILD_TRIGGER", "push")

proc bitbucketGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getBitbucketMetadata()

proc bitbucketGetRunTimeHostInfo(self: Plugin,
                                 chalks: seq[ChalkObj],
                                 ): ChalkDict {.cdecl.} =
  return self.getBitbucketMetadata(prefix = "_")

proc loadCiBitbucket*() =
  newPlugin("ci_bitbucket",
            ctHostCallback = ChalkTimeHostCb(bitbucketGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(bitbucketGetRunTimeHostInfo))
