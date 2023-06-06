## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.
##
## :Author: Rich Smith (rich@crashoverride.com) heaviily based on
## code by Miroslav Shubernetskiy (miroslav@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import tables,os
import nimutils, ../types, ../plugins

type JenkinsCI = ref object of Plugin

method getHostInfo*(self: JenkinsCI, path: seq[string], ins: bool): ChalkDict =
  result = ChalkDict()

  # https://www.jenkins.io/doc/book/pipeline/
  #                        jenkinsfile/#using-environment-variables
  let
    CI = os.getEnv("CI")

    # The current build ID, identical to BUILD_NUMBER for builds
    #                            created in Jenkins versions 1.597+
    JENKINS_BUILD_ID = os.getEnv("BUILD_ID")

    # The URL where the results of this build can be found
    # (for example http://buildserver/jenkins/job/MyJobName/17/ )
    JENKINS_BUILD_URL = os.getEnv("BUILD_URL")

    # Full URL of Jenkins, such as
    # https://example.com:port/jenkins/
    JENKINS_URL = os.getEnv("JENKINS_URL")

  # probably not running in jenkinsCI
  if CI == "" and JENKINS_BUILD_ID == "": return

  if JENKINS_BUILD_ID != "":
    result["BUILD_ID"] = pack(JENKINS_BUILD_ID)

  if JENKINS_BUILD_URL != "":
    result["BUILD_URI"] = pack(JENKINS_BUILD_URL)

  if JENKINS_URL != "":
    result["BUILD_API_URI"] = pack(JENKINS_URL)

registerPlugin("ci_jenkins", JenkinsCI())
