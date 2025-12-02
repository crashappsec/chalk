##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## github CI environment.

import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
  utils/files,
  utils/http,
  utils/json,
]

proc getRepo(api: string, repo: string): JsonNode =
  # https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#get-a-repository
  result = newJObject()
  let token = getEnv("GITHUB_TOKEN")
  if token == "":
    warn("github: GITHUB_TOKEN is empty. " &
         "If this is running inside GitHub action, make sure ${{ github.token }} is explicitly passed. " &
         "See https://docs.github.com/en/actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow")
    return
  if not api.startsWith("http://") and not api.startsWith("https://"):
    warn("github: invalid api url (" & api & "). Cannot query repo node id")
    return
  let
    url      = api.strip(chars = {'/'}, leading = false) & "/repos/" & repo.strip(chars = {'/'}, trailing = false)
    headers  = newHttpHeaders({"Authorization": "Bearer " & token})
    response = safeRequest(url, httpMethod = HttpGet, headers = headers)
  if not response.code().is2xx():
    warn("github: could not fetch repo info from " & url & ". " &
         "Received " & response.status)
    return
  return parseJson(response.body())

proc getGithubMetadata(self: Plugin, prefix=""): ChalkDict =
  result = ChalkDict()

  # https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
  # https://docs.github.com/en/actions/reference/workflows-and-actions/variables
  let
    CI                         = getEnv("CI")
    GITHUB_SHA                 = getEnv("GITHUB_SHA")
    GITHUB_SERVER_URL          = getEnv("GITHUB_SERVER_URL")
    GITHUB_REPOSITORY          = getEnv("GITHUB_REPOSITORY")
    GITHUB_REPOSITORY_ID       = getEnv("GITHUB_REPOSITORY_ID")
    GITHUB_REPOSITORY_OWNER_ID = getEnv("GITHUB_REPOSITORY_OWNER_ID")
    GITHUB_RUN_ID              = getEnv("GITHUB_RUN_ID") # workflow ID
    GITHUB_CHECK_RUN_ID        = getEnv("GITHUB_CHECK_RUN_ID") # job ID - set by setup-chalk-action
    GITHUB_RUN_ATTEMPT         = getEnv("GITHUB_RUN_ATTEMPT")
    GITHUB_API_URL             = getEnv("GITHUB_API_URL")
    GITHUB_ACTOR               = getEnv("GITHUB_ACTOR")
    GITHUB_EVENT_NAME          = getEnv("GITHUB_EVENT_NAME")
    GITHUB_REF                 = getEnv("GITHUB_REF")
    GITHUB_REF_TYPE            = getEnv("GITHUB_REF_TYPE")
    GITHUB_WORKFLOW            = getEnv("GITHUB_WORKFLOW")
    GITHUB_WORKFLOW_REF        = getEnv("GITHUB_WORKFLOW_REF")
    GITHUB_WORKFLOW_SHA        = getEnv("GITHUB_WORKFLOW_SHA")
    RUNNER_TEMP                = getEnv("RUNNER_TEMP")

  # probably not running in github CI
  if CI == "" and GITHUB_SHA == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              coalesce(GITHUB_CHECK_RUN_ID, GITHUB_RUN_ID))
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       GITHUB_SHA)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       GITHUB_REPOSITORY_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", GITHUB_REPOSITORY_OWNER_ID)
  result.setIfNeeded(prefix & "BUILD_API_URI",         GITHUB_API_URL)
  result.setIfNeeded(prefix & "BUILD_ATTEMPT",         GITHUB_RUN_ATTEMPT)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   GITHUB_WORKFLOW)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   GITHUB_WORKFLOW_REF)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_HASH",   GITHUB_WORKFLOW_SHA)
  result.setIfNeeded(prefix & "BUILD_REF",             GITHUB_REF)

  if RUNNER_TEMP != "":
    # RUNNER_TEMP is automatically cleaned up by GitHub at the end of the job execution
    # so we can safely write to it and have a guarantee it will be unique for the job duration
    let uniquePath = RUNNER_TEMP.joinPath("BUILD_UNIQUE_ID.chalk")
    result.trySetIfNeeded(
      prefix & "BUILD_UNIQUE_ID",
      getOrWriteExclusiveFile(uniquePath, secureRand[uint64]().toHex().toLower()),
    )

  if GITHUB_SERVER_URL != "" and GITHUB_REPOSITORY != "" and GITHUB_RUN_ID != "":
    let base = (
      GITHUB_SERVER_URL.strip(leading = false, chars = {'/'}) & "/" &
      GITHUB_REPOSITORY.strip(chars = {'/'})
    )
    # https://github.com/crashappsec/setup-chalk-action-test/actions/runs/17955140101/job/51064362862
    var uri = base & "/actions/runs/" & GITHUB_RUN_ID
    # check id is set by the setup-chalk-action
    # but its not an official env var just yet as its only available via github job context
    # https://github.com/orgs/community/discussions/8945#discussioncomment-14374985
    if GITHUB_CHECK_RUN_ID != "":
      uri = uri.strip(chars = {'/'}) & "/job/" & GITHUB_CHECK_RUN_ID
    elif GITHUB_RUN_ATTEMPT != "":
      uri = uri.strip(chars = {'/'}) & "/attempts/" & GITHUB_RUN_ATTEMPT
    result.setIfNeeded(prefix & "BUILD_ORIGIN_URI", base)
    result.setIfNeeded(prefix & "BUILD_URI",        uri)

  if GITHUB_API_URL != "" and (
    isSubscribedKey(prefix & "BUILD_ORIGIN_KEY") or
    isSubscribedKey(prefix & "BUILD_ORIGIN_OWNER_KEY")
  ):
    try:
      let data = getRepo(GITHUB_API_URL, GITHUB_REPOSITORY)
      result.setIfNeeded(prefix & "BUILD_ORIGIN_KEY",       data{"node_id"}.getStr())
      result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_KEY", data{"owner"}{"node_id"}.getStr())
    except:
      warn("github: could not fetch repo info: " & getCurrentExceptionMsg())

  # https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows
  if GITHUB_EVENT_NAME == "push" and GITHUB_REF_TYPE == "tag":
    result.setIfNeeded(prefix & "BUILD_TRIGGER", "tag")
  else:
    result.setIfNeeded(prefix & "BUILD_TRIGGER", GITHUB_EVENT_NAME)

  if GITHUB_ACTOR != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[GITHUB_ACTOR])

proc githubGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getGithubMetadata()

proc githubGetRunTimeHostInfo(self: Plugin,
                              chalks: seq[ChalkObj],
                              ): ChalkDict {.cdecl.} =
  return self.getGithubMetadata(prefix = "_")

proc loadCiGitHub*() =
  newPlugin("ci_github",
            ctHostCallback = ChalkTimeHostCb(githubGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(githubGetRunTimeHostInfo))
