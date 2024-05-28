##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## github CI environment.


import ".."/[config, plugin_api]

proc githubGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()

  # https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
  let
    CI                         = getEnv("CI")
    GITHUB_SHA                 = getEnv("GITHUB_SHA")
    GITHUB_SERVER_URL          = getEnv("GITHUB_SERVER_URL")
    GITHUB_REPOSITORY          = getEnv("GITHUB_REPOSITORY")
    GITHUB_REPOSITORY_ID       = getEnv("GITHUB_REPOSITORY_ID")
    GITHUB_REPOSITORY_OWNER_ID = getEnv("GITHUB_REPOSITORY_OWNER_ID")
    GITHUB_RUN_ID              = getEnv("GITHUB_RUN_ID")
    GITHUB_API_URL             = getEnv("GITHUB_API_URL")
    GITHUB_ACTOR               = getEnv("GITHUB_ACTOR")
    GITHUB_EVENT_NAME          = getEnv("GITHUB_EVENT_NAME")
    GITHUB_REF_TYPE            = getEnv("GITHUB_REF_TYPE")

  # probably not running in github CI
  if CI == "" and GITHUB_SHA == "": return

  result.setIfNeeded("BUILD_ID",              GITHUB_RUN_ID)
  result.setIfNeeded("BUILD_ORIGIN_ID",       GITHUB_REPOSITORY_ID)
  result.setIfNeeded("BUILD_ORIGIN_OWNER_ID", GITHUB_REPOSITORY_OWNER_ID)
  result.setIfNeeded("BUILD_API_URI",         GITHUB_API_URL)

  if (GITHUB_SERVER_URL != "" and GITHUB_REPOSITORY != "" and
      GITHUB_RUN_ID != ""):
    result.setIfNeeded("BUILD_URI", (
      GITHUB_SERVER_URL.strip(leading = false, chars = {'/'}) & "/" &
      GITHUB_REPOSITORY.strip(chars = {'/'}) & "/actions/runs/" &
      GITHUB_RUN_ID
    ))

  # https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows
  if GITHUB_EVENT_NAME != "" and GITHUB_REF_TYPE != "":
    if GITHUB_EVENT_NAME == "push" and GITHUB_REF_TYPE == "tag":
      result.setIfNeeded("BUILD_TRIGGER", "tag")
    elif GITHUB_EVENT_NAME == "push":
      result.setIfNeeded("BUILD_TRIGGER", "push")
    elif GITHUB_EVENT_NAME == "workflow_dispatch":
      result.setIfNeeded("BUILD_TRIGGER", "manual")
    elif GITHUB_EVENT_NAME == "workflow_call":
      result.setIfNeeded("BUILD_TRIGGER", "external")
    elif GITHUB_EVENT_NAME == "schedule":
      result.setIfNeeded("BUILD_TRIGGER", "schedule")
    else:
      result.setIfNeeded("BUILD_TRIGGER", "other: " & GITHUB_EVENT_NAME)

  if GITHUB_ACTOR != "": result.setIfNeeded("BUILD_CONTACT", @[GITHUB_ACTOR])

proc loadCiGitHub*() =
  newPlugin("ci_github",
            ctHostCallback = ChalkTimeHostCb(githubGetChalkTimeHostInfo))
