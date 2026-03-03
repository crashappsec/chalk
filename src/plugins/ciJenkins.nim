##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getJenkinsMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://www.jenkins.io/doc/book/pipeline/jenkinsfile/#using-environment-variables
  let
    CI                = getEnv("CI")
    JENKINS_BUILD_ID  = getEnv("BUILD_ID")
    JENKINS_BUILD_NUM = getEnv("BUILD_NUMBER")
    JENKINS_BUILD_URL = getEnv("BUILD_URL")
    JENKINS_URL       = getEnv("JENKINS_URL")
    JENKINS_JOB_NAME  = getEnv("JOB_NAME")
    JENKINS_JOB_URL   = getEnv("JOB_URL")
    JENKINS_NODE_NAME = getEnv("NODE_NAME")
    JENKINS_BUILD_TAG = getEnv("BUILD_TAG")
    GIT_COMMIT        = getEnv("GIT_COMMIT")
    GIT_BRANCH        = getEnv("GIT_BRANCH")
    GIT_URL           = getEnv("GIT_URL")
    BUILD_CAUSE       = getEnv("BUILD_CAUSE")

  # probably not running in Jenkins CI
  if CI == "" and JENKINS_BUILD_ID == "": return

  result.setIfNeeded(prefix & "BUILD_ID",            JENKINS_BUILD_ID)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",     GIT_COMMIT)
  result.setIfNeeded(prefix & "BUILD_URI",           JENKINS_BUILD_URL)
  result.setIfNeeded(prefix & "BUILD_API_URI",       JENKINS_URL)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_ID",     JENKINS_JOB_NAME)
  result.setIfNeeded(prefix & "BUILD_ORIGIN_URI",    GIT_URL)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME", JENKINS_JOB_NAME)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH", JENKINS_JOB_URL)
  result.setIfNeeded(prefix & "BUILD_TRIGGER",       BUILD_CAUSE)

  if GIT_BRANCH != "":
    var buildRef = GIT_BRANCH
    if not buildRef.startsWith("refs/"):
      buildRef = "refs/heads/" & buildRef
    result.setIfNeeded(prefix & "BUILD_REF", buildRef)

  if JENKINS_NODE_NAME != "":
    result.setIfNeeded(prefix & "BUILD_CONTACT", @[JENKINS_NODE_NAME])

proc jenkinsGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getJenkinsMetadata()

proc jenkinsGetRunTimeHostInfo(self: Plugin,
                              chalks: seq[ChalkObj],
                              ): ChalkDict {.cdecl.} =
  return self.getJenkinsMetadata(prefix = "_")

proc loadCiJenkins*() =
  newPlugin("ci_jenkins",
            ctHostCallback = ChalkTimeHostCb(jenkinsGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(jenkinsGetRunTimeHostInfo))
