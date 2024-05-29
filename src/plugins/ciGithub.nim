##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## github CI environment.

import std/[json, httpclient, strutils]
import ".."/[config, plugin_api]

proc getRepoNodeId(api: string, repo: string): string =
  # https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#get-a-repository
  let token = getEnv("GITHUB_TOKEN")
  if token == "":
    warn("github: GITHUB_TOKEN is empty. " &
         "If this is running inside GitHub action, make sure ${{ github.token }} is explicitly passed. " &
         "See https://docs.github.com/en/actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow")
    return ""
  if not api.startsWith("http://") and not api.startsWith("https://"):
    warn("github: invalid api url (" & api & "). Cannot query repo node id")
    return ""
  let
    url      = api.strip(chars = {'/'}, leading = false) & "/repos/" & repo.strip(chars = {'/'}, trailing = false)
    headers  = newHttpHeaders({"Authorization": "Bearer " & token})
    response = safeRequest(url, httpMethod = HttpGet, headers = headers)
  if not response.code().is2xx():
    warn("github: could not fetch repo info from " & url & ". " &
         "Received " & response.status)
    return ""
  let data = parseJson(response.body())
  return data{"node_id"}.getStr()

proc githubGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
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

  if GITHUB_API_URL != "" and isSubscribedKey("BUILD_ORIGIN_KEY"):
    try:
      result.setIfNeeded("BUILD_ORIGIN_KEY", getRepoNodeId(GITHUB_API_URL, GITHUB_REPOSITORY))
    except:
      warn("github: could not fetch repo node id: " & getCurrentExceptionMsg())

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
