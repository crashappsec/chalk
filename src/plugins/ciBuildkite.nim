##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Buildkite CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getBuildkiteMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://buildkite.com/docs/pipelines/environment-variables
  let
    BUILDKITE                       = getEnv("BUILDKITE")
    BUILDKITE_BUILD_ID              = getEnv("BUILDKITE_BUILD_ID")
    BUILDKITE_BUILD_NUMBER          = getEnv("BUILDKITE_BUILD_NUMBER")
    BUILDKITE_BUILD_URL             = getEnv("BUILDKITE_BUILD_URL")
    BUILDKITE_COMMIT                = getEnv("BUILDKITE_COMMIT")
    BUILDKITE_BRANCH                = getEnv("BUILDKITE_BRANCH")
    BUILDKITE_TAG                   = getEnv("BUILDKITE_TAG")
    BUILDKITE_MESSAGE               = getEnv("BUILDKITE_MESSAGE")
    BUILDKITE_BUILD_CREATOR         = getEnv("BUILDKITE_BUILD_CREATOR")
    BUILDKITE_BUILD_CREATOR_EMAIL   = getEnv("BUILDKITE_BUILD_CREATOR_EMAIL")
    BUILDKITE_ORGANIZATION_SLUG     = getEnv("BUILDKITE_ORGANIZATION_SLUG")
    BUILDKITE_PIPELINE_SLUG         = getEnv("BUILDKITE_PIPELINE_SLUG")
    BUILDKITE_PIPELINE_ID           = getEnv("BUILDKITE_PIPELINE_ID")
    BUILDKITE_JOB_ID                = getEnv("BUILDKITE_JOB_ID")
    BUILDKITE_STEP_KEY              = getEnv("BUILDKITE_STEP_KEY")
    BUILDKITE_SOURCE                = getEnv("BUILDKITE_SOURCE")
    BUILDKITE_REPO                  = getEnv("BUILDKITE_REPO")
    BUILDKITE_TRIGGERED_FROM_BUILD_ID = getEnv("BUILDKITE_TRIGGERED_FROM_BUILD_ID")

  # probably not running in Buildkite CI
  if BUILDKITE == "" and BUILDKITE_BUILD_ID == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              BUILDKITE_JOB_ID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       BUILDKITE_COMMIT)
  result.setIfNeeded(prefix & "BUILD_URI",             BUILDKITE_BUILD_URL)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       BUILDKITE_PIPELINE_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", BUILDKITE_ORGANIZATION_SLUG)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",      BUILDKITE_REPO)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   BUILDKITE_PIPELINE_SLUG)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   BUILDKITE_STEP_KEY)
  result.setIfNeeded(prefix & "BUILD_TRIGGER",         BUILDKITE_SOURCE)

  # Construct BUILD_REF to match GitHub's refs/tags/ or refs/heads/ convention
  if BUILDKITE_TAG != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/tags/" & BUILDKITE_TAG)
  elif BUILDKITE_BRANCH != "":
    result.setIfNeeded(prefix & "BUILD_REF", "refs/heads/" & BUILDKITE_BRANCH)

  if BUILDKITE_BUILD_CREATOR != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[BUILDKITE_BUILD_CREATOR])

proc buildkiteGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getBuildkiteMetadata()

proc buildkiteGetRunTimeHostInfo(self: Plugin,
                                 chalks: seq[ChalkObj],
                                 ): ChalkDict {.cdecl.} =
  return self.getBuildkiteMetadata(prefix = "_")

proc loadCiBuildkite*() =
  newPlugin("ci_buildkite",
            ctHostCallback = ChalkTimeHostCb(buildkiteGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(buildkiteGetRunTimeHostInfo))
