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
    CI = getEnv("CI")

    # The current build ID, identical to BUILD_NUMBER for builds
    #                            created in Jenkins versions 1.597+
    JENKINS_BUILD_ID = getEnv("BUILD_ID")

    # The URL where the results of this build can be found
    # (for example http://buildserver/jenkins/job/MyJobName/17/ )
    JENKINS_BUILD_URL = getEnv("BUILD_URL")

    # Full URL of Jenkins, such as
    # https://example.com:port/jenkins/
    JENKINS_URL = getEnv("JENKINS_URL")

  # probably not running in jenkinsCI
  if CI == "" and JENKINS_BUILD_ID == "": return

  result.setIfNeeded(prefix & "BUILD_ID",      JENKINS_BUILD_ID)
  result.setIfNeeded(prefix & "BUILD_URI",     JENKINS_BUILD_URL)
  result.setIfNeeded(prefix & "BUILD_API_URI", JENKINS_URL)

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
