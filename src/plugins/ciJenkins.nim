## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.
##
## :Author: Rich Smith (rich@crashoverride.com) heaviily based on
## code by Miroslav Shubernetskiy (miroslav@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import ../config, ../plugin_api

proc jenkinsGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()

  # https://www.jenkins.io/doc/book/pipeline/
  #                        jenkinsfile/#using-environment-variables
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

  if JENKINS_BUILD_ID != "":
    result["BUILD_ID"] = pack(JENKINS_BUILD_ID)

  if JENKINS_BUILD_URL != "":
    result["BUILD_URI"] = pack(JENKINS_BUILD_URL)

  if JENKINS_URL != "":
    result["BUILD_API_URI"] = pack(JENKINS_URL)

proc loadCiJenkins*() =
  newPlugin("ci_jenkins",
            ctHostCallback = ChalkTimeHostCb(jenkinsGetChalkTimeHostInfo))
