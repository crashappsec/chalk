##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## TeamCity CI environment.


import ".."/[
  plugin_api,
  run_management,
  types,
  utils/envvars,
]

proc getTeamcityMetadata(self: Plugin, prefix = ""): ChalkDict =
  result = ChalkDict()

  # https://www.jetbrains.com/help/teamcity/predefined-build-parameters.html
  let
    TEAMCITY_VERSION       = getEnv("TEAMCITY_VERSION")
    BUILD_NUMBER           = getEnv("BUILD_NUMBER")
    BUILD_VCS_NUMBER       = getEnv("BUILD_VCS_NUMBER")
    BUILD_URL              = getEnv("BUILD_URL")
    TEAMCITY_PROJECT_NAME  = getEnv("TEAMCITY_PROJECT_NAME")
    TEAMCITY_BUILDCONF     = getEnv("TEAMCITY_BUILDCONF_NAME")
    TC_PROPS_FILE          = getEnv("TEAMCITY_BUILD_PROPERTIES_FILE")

  # probably not running in TeamCity
  if TEAMCITY_VERSION == "": return

  result.setIfNeeded(prefix & "BUILD_ID",            BUILD_NUMBER)
  result.setIfNeeded(prefix & "BUILD_COMMIT_ID",     BUILD_VCS_NUMBER)
  result.setIfNeeded(prefix & "BUILD_URI",           BUILD_URL)
  result.setIfNeeded(prefix & "BUILD_WORKFLOW_NAME", TEAMCITY_BUILDCONF)

  # Parse system properties from the properties file for richer metadata
  if TC_PROPS_FILE != "":
    try:
      let props = readFile(TC_PROPS_FILE)
      for line in props.splitLines():
        let parts = line.split('=', maxsplit=1)
        if parts.len == 2:
          let (key, val) = (parts[0].strip(), parts[1].strip())
          case key
          of "teamcity.build.id":
            result.setIfNeeded(prefix & "BUILD_ID", val)
          of "teamcity.serverUrl":
            result.setIfNeeded(prefix & "BUILD_API_URI", val)
          of "teamcity.buildType.id":
            result.setIfNeeded(prefix & "BUILD_WORKFLOW_PATH", val)
          of "teamcity.build.branch":
            var buildRef = val
            if buildRef != "" and not buildRef.startsWith("refs/"):
              buildRef = "refs/heads/" & buildRef
            result.setIfNeeded(prefix & "BUILD_REF", buildRef)
          of "teamcity.build.triggeredBy.username":
            if val != "":
              result.setIfNeeded(prefix & "BUILD_CONTACT", @[val])
          else:
            discard
    except:
      discard  # Properties file not readable; use env vars only

proc teamcityGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  return self.getTeamcityMetadata()

proc teamcityGetRunTimeHostInfo(self: Plugin,
                                chalks: seq[ChalkObj],
                                ): ChalkDict {.cdecl.} =
  return self.getTeamcityMetadata(prefix = "_")

proc loadCiTeamcity*() =
  newPlugin("ci_teamcity",
            ctHostCallback = ChalkTimeHostCb(teamcityGetChalkTimeHostInfo),
            rtHostCallback = RunTimeHostCb(teamcityGetRunTimeHostInfo))
