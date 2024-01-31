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

  # https://docs.github.com/en/actions/
  #              learn-github-actions/variables#default-environment-variables
  let
    CI                = getEnv("CI")
    GITHUB_SHA        = getEnv("GITHUB_SHA")
    GITHUB_SERVER_URL = getEnv("GITHUB_SERVER_URL")
    GITHUB_REPOSITORY = getEnv("GITHUB_REPOSITORY")
    GITHUB_RUN_ID     = getEnv("GITHUB_RUN_ID")
    GITHUB_API_URL    = getEnv("GITHUB_API_URL")
    GITHUB_ACTOR      = getEnv("GITHUB_ACTOR")
    GITHUB_EVENT_NAME = getEnv("GITHUB_EVENT_NAME")
    GITHUB_REF_TYPE   = getEnv("GITHUB_REF_TYPE")

  # probably not running in github CI
  if CI == "" and GITHUB_SHA == "": return

  if GITHUB_RUN_ID != "":  result["BUILD_ID"] = pack(GITHUB_RUN_ID)

  if (GITHUB_SERVER_URL != "" and GITHUB_REPOSITORY != "" and
      GITHUB_RUN_ID != ""):
    result["BUILD_URI"] = pack(
      GITHUB_SERVER_URL.strip(leading = false, chars = {'/'}) & "/" &
      GITHUB_REPOSITORY.strip(chars = {'/'}) & "/actions/runs/" &
      GITHUB_RUN_ID
    )

  if GITHUB_API_URL != "": result["BUILD_API_URI"] = pack(GITHUB_API_URL)

  # https://docs.github.com/en/actions/using-workflows/
  #                                    events-that-trigger-workflows
  if GITHUB_EVENT_NAME != "" and GITHUB_REF_TYPE != "":
    if GITHUB_EVENT_NAME == "push" and GITHUB_REF_TYPE == "tag":
      result["BUILD_TRIGGER"] = pack("tag")
    elif GITHUB_EVENT_NAME == "push":
      result["BUILD_TRIGGER"] = pack("push")
    elif GITHUB_EVENT_NAME == "workflow_dispatch":
      result["BUILD_TRIGGER"] = pack("manual")
    elif GITHUB_EVENT_NAME == "workflow_call":
      result["BUILD_TRIGGER"] = pack("external")
    elif GITHUB_EVENT_NAME == "schedule":
      result["BUILD_TRIGGER"] = pack("schedule")
    else:
      result["BUILD_TRIGGER"] = pack("other: " & GITHUB_EVENT_NAME)

  if GITHUB_ACTOR != "": result["BUILD_CONTACT"] = pack(@[GITHUB_ACTOR])

proc loadCiGitHub*() =
  newPlugin("ci_github",
            ctHostCallback = ChalkTimeHostCb(githubGetChalkTimeHostInfo))
