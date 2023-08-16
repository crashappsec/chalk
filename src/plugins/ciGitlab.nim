## This plugin is responsible for providing metadata gleaned from a
## Gitlab CI environment.
##
## :Author: Rich Smith (rich@crashoverride.com) heaviily based on
## code by Miroslav Shubernetskiy (miroslav@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import ../config, ../plugin_api

proc gitlabGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.}  =
  result = ChalkDict()

  # https://docs.gitlab.com/ee/ci/variables/predefined_variables.html
  let
    CI                = getEnv("CI")
    GITLAB_CI         = getEnv("GITLAB_CI")
    GITLAB_JOB_URL    = getEnv("CI_JOB_URL")
    GITLAB_JOB_ID     = getEnv("CI_JOB_ID")
    GITLAB_API_URL    = getEnv("CI_API_V4_URL")
    GITLAB_USER       = getEnv("GITLAB_USER_LOGIN")
    GITLAB_EVENT_NAME = getEnv("CI_PIPELINE_SOURCE")

  # probably not running in gitlab CI
  if CI == "" and GITLAB_CI == "": return

  if GITLAB_JOB_ID != "":  result["BUILD_ID"]      = pack(GITLAB_JOB_ID)

  if GITLAB_JOB_URL != "": result["BUILD_URI"]     = pack(GITLAB_JOB_URL)

  if GITLAB_API_URL != "": result["BUILD_API_URI"] = pack(GITLAB_API_URL)

  # https://docs.gitlab.com/ee/ci/jobs
  #                     /job_control.html#common-if-clauses-for-rules
  if GITLAB_EVENT_NAME != "" :
      result["BUILD_TRIGGER"] = pack(GITLAB_EVENT_NAME)

  # Lots of potential 'user' vars to pick from here, long term will likely
  #  need to be configurable as different customers will attach different
  #  meaning to different user value depending on their pipeline
  if GITLAB_USER != "": result["BUILD_CONTACT"] = pack(@[GITLAB_USER])

proc loadCiGitlab*() =
  newPlugin("ci_gitlab",
            ctHostCallback = ChalkTimeHostCb(gitlabGetChalkTimeHostInfo))
