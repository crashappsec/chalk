##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## AWS Code Build CI environment.

import std/[strutils]
import ".."/[config, plugin_api]

proc codeBuildGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()

  # https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-env-vars.html
  let
    CODEBUILD_BUILD_ARN               = getEnv("CODEBUILD_BUILD_ARN")
    CODEBUILD_INITIATOR               = getEnv("CODEBUILD_INITIATOR")
    CODEBUILD_SOURCE_VERSION          = getEnv("CODEBUILD_SOURCE_VERSION")
    CODEBUILD_RESOLVED_SOURCE_VERSION = getEnv("CODEBUILD_RESOLVED_SOURCE_VERSION")
    CODEBUILD_SOURCE_REPO_URL         = getEnv("CODEBUILD_SOURCE_REPO_URL")
    CODEBUILD_PUBLIC_BUILD_URL        = getEnv("CODEBUILD_PUBLIC_BUILD_URL")
    CODEBUILD_WEBHOOK_TRIGGER         = getEnv("CODEBUILD_WEBHOOK_TRIGGER")

  # probably not running in github CI
  if CODEBUILD_BUILD_ARN == "" and CODEBUILD_SOURCE_REPO_URL == "": return

  let
    isS3          = CODEBUILD_SOURCE_REPO_URL.startsWith("s3://")
    versionSuffix =
      if isS3 and CODEBUILD_SOURCE_VERSION != "":
        # https://docs.aws.amazon.com/AmazonS3/latest/userguide/RetrievingObjectVersions.html
        "?versionId=" & CODEBUILD_SOURCE_VERSION
      else:
        ""

  result.setIfNeeded("BUILD_URI",         CODEBUILD_PUBLIC_BUILD_URL)
  result.setIfNeeded("BUILD_ID",          CODEBUILD_BUILD_ARN)
  result.setIfNeeded("BUILD_ORIGIN_URI",  CODEBUILD_SOURCE_REPO_URL & versionSuffix)
  if not isS3:
    result.setIfNeeded("BUILD_COMMIT_ID", CODEBUILD_RESOLVED_SOURCE_VERSION)

  if CODEBUILD_WEBHOOK_TRIGGER != "":
    let event = CODEBUILD_WEBHOOK_TRIGGER.split("/")[0]
    case event
    of "tag":
      result.setIfNeeded("BUILD_TRIGGER", "tag")
    of "branch", "pr":
      result.setIfNeeded("BUILD_TRIGGER", "push")
    else:
      result.setIfNeeded("BUILD_TRIGGER", "other: " & event)

  if CODEBUILD_INITIATOR != "":
    result.setIfNeeded("BUILD_CONTACT", @[CODEBUILD_INITIATOR])

proc loadCiCodeBuild*() =
  newPlugin("ci_codebuild",
            ctHostCallback = ChalkTimeHostCb(codeBuildGetChalkTimeHostInfo))
