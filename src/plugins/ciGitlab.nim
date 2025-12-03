##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Gitlab CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getGitlabMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://docs.gitlab.com/ee/ci/variables/predefined_variables.html
  let
    CI                        = getEnv("CI")
    GITLAB_CI                 = getEnv("GITLAB_CI")
    CI_COMMIT_SHA             = getEnv("CI_COMMIT_SHA")
    CI_JOB_URL                = getEnv("CI_JOB_URL")
    CI_JOB_ID                 = getEnv("CI_JOB_ID")
    CI_API_V4_URL             = getEnv("CI_API_V4_URL")
    CI_PROJECT_URL            = getEnv("CI_PROJECT_URL")
    CI_PROJECT_ID             = getEnv("CI_PROJECT_ID")
    CI_PROJECT_NAMESPACE_ID   = getEnv("CI_PROJECT_NAMESPACE_ID")
    GITLAB_USER_LOGIN         = getEnv("GITLAB_USER_LOGIN")
    CI_PIPELINE_SOURCE        = getEnv("CI_PIPELINE_SOURCE")
    CI_CONFIG_PATH            = getEnv("CI_CONFIG_PATH")
    CI_PIPELINE_NAME          = getEnv("CI_PIPELINE_NAME")
    CI_MERGE_REQUEST_REF_PATH = getEnv("CI_MERGE_REQUEST_REF_PATH")

  # probably not running in gitlab CI
  if CI == "" and GITLAB_CI == "": return

  result.setIfNeeded(prefix & "BUILD_ID",              CI_JOB_ID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",       CI_COMMIT_SHA)
  result.setIfNeeded(prefix & "BUILD_URI",             CI_JOB_URL)
  result.setIfNeeded(prefix & "BUILD_API_URI",         CI_API_V4_URL)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",       CI_PROJECT_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_OWNER_ID", CI_PROJECT_NAMESPACE_ID)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",      CI_PROJECT_URL)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME",   CI_PIPELINE_NAME)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH",   CI_CONFIG_PATH)
  result.setIfNeeded(prefix & "BUILD_REF",             CI_MERGE_REQUEST_REF_PATH)

  # https://docs.gitlab.com/ci/jobs/job_rules/#ci_pipeline_source-predefined-variable
  result.setIfNeeded(prefix & "BUILD_TRIGGER", CI_PIPELINE_SOURCE)

  # Lots of potential 'user' vars to pick from here, long term will likely
  #  need to be configurable as different customers will attach different
  #  meaning to different user value depending on their pipeline
  if GITLAB_USER_LOGIN != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[GITLAB_USER_LOGIN])

proc gitlabGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getGitlabMetadata()

proc gitlabGetRunTimeHostInfo(self: Plugin,
                              chalks: seq[ChalkObj],
                              ): ChalkDict {.cdecl.} =
  return self.getGitlabMetadata(prefix = "_")

proc loadCiGitlab*() =
  newPlugin("ci_gitlab",
            ctHostCallback = ChalkTimeHostCb(gitlabGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(gitlabGetRunTimeHostInfo))
