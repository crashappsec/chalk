##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Gitlab CI environment.


import ".."/[config, plugin_api]

proc gitlabGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.}  =
  result = ChalkDict()

  # https://docs.gitlab.com/ee/ci/variables/predefined_variables.html
  let
    CI                  = getEnv("CI")
    GITLAB_CI           = getEnv("GITLAB_CI")
    GITLAB_COMMIT_SHA   = getEnv("CI_COMMIT_SHA")
    GITLAB_JOB_URL      = getEnv("CI_JOB_URL")
    GITLAB_JOB_ID       = getEnv("CI_JOB_ID")
    GITLAB_API_URL      = getEnv("CI_API_V4_URL")
    GITLAB_PROJECT_URL  = getEnv("CI_PROJECT_URL")
    GITLAB_PROJECT_ID   = getEnv("CI_PROJECT_ID")
    GITLAB_NAMESPACE_ID = getEnv("CI_PROJECT_NAMESPACE_ID")
    GITLAB_USER         = getEnv("GITLAB_USER_LOGIN")
    GITLAB_EVENT_NAME   = getEnv("CI_PIPELINE_SOURCE")

  # probably not running in gitlab CI
  if CI == "" and GITLAB_CI == "": return

  result.setIfNeeded("BUILD_ID",              GITLAB_JOB_ID)
  result.setIfNeeded("BUILD_COMMIT_ID",       GITLAB_COMMIT_SHA)
  result.setIfNeeded("BUILD_URI",             GITLAB_JOB_URL)
  result.setIfNeeded("BUILD_API_URI",         GITLAB_API_URL)
  result.setIfNeeded("BUILD_ORIGIN_ID",       GITLAB_PROJECT_ID)
  result.setIfNeeded("BUILD_ORIGIN_OWNER_ID", GITLAB_NAMESPACE_ID)
  result.setIfNeeded("BUILD_ORIGIN_URI",      GITLAB_PROJECT_URL)

  # https://docs.gitlab.com/ee/ci/jobs/job_control.html#common-if-clauses-for-rules
  result.setIfNeeded("BUILD_TRIGGER", GITLAB_EVENT_NAME)

  # Lots of potential 'user' vars to pick from here, long term will likely
  #  need to be configurable as different customers will attach different
  #  meaning to different user value depending on their pipeline
  if GITLAB_USER != "": result.setIfNeeded("BUILD_CONTACT", @[GITLAB_USER])

proc loadCiGitlab*() =
  newPlugin("ci_gitlab",
            ctHostCallback = ChalkTimeHostCb(gitlabGetChalkTimeHostInfo))
