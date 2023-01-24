import tables, strformat, strutils, os
import nimutils, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type GithubCI = ref object of Plugin

method getArtifactInfo*(self: GithubCI,
                        sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  # https://docs.github.com/en/actions/
  #              learn-github-actions/variables#default-environment-variables
  let
    CI                = os.getEnv("CI")
    GITHUB_SHA        = os.getEnv("GITHUB_SHA")
    GITHUB_SERVER_URL = os.getEnv("GITHUB_SERVER_URL")
    GITHUB_REPOSITORY = os.getEnv("GITHUB_REPOSITORY")
    GITHUB_RUN_ID     = os.getEnv("GITHUB_RUN_ID")
    GITHUB_API_URL    = os.getEnv("GITHUB_API_URL")
    GITHUB_ACTOR      = os.getEnv("GITHUB_ACTOR")
    GITHUB_EVENT_NAME = os.getEnv("GITHUB_EVENT_NAME")
    GITHUB_REF_TYPE   = os.getEnv("GITHUB_REF_TYPE")

  # probably not running in github CI
  if CI == "" and GITHUB_SHA == "":
    return

  if GITHUB_RUN_ID != "":
    result["BUILD_ID"] = pack(GITHUB_RUN_ID)

  if (
    GITHUB_SERVER_URL != "" and
    GITHUB_REPOSITORY != "" and
    GITHUB_RUN_ID != ""
  ):
    result["BUILD_URI"] = pack(
      GITHUB_SERVER_URL.strip(leading = false, chars = {'/'}) &
      "/" &
      GITHUB_REPOSITORY.strip(chars = {'/'}) &
      "/actions/runs/" &
      GITHUB_RUN_ID
    )

  if GITHUB_API_URL != "":
    result["BUILD_API_URI"] = pack(GITHUB_API_URL)

  # https://docs.github.com/en/actions/using-workflows/
  #                                    events-that-trigger-workflows
  if (
    GITHUB_EVENT_NAME != "" and
    GITHUB_REF_TYPE != ""
  ):
    if GITHUB_EVENT_NAME == "push" and GITHUB_REF_TYPE == "tag":
      result["BUILD_TRIGGER"] = pack("tag")
    elif GITHUB_EVENT_NAME == "push":
      result["BUILD_TRIGGER"] = pack("push")
    elif GITHUB_EVENT_NAME == "workflow_dispatch":
      result["BUILD_TRIGGER"] = pack("manual")
    elif GITHUB_EVENT_NAME == "workflow_call":
      result["BUILD_TRIGGER"] = pack("external")
    elif GITHUB_EVENT_NAME == "schedule":
      result["BUILD_TRIGGER"] = pack("schedule")
    else:
      result["BUILD_TRIGGER"] = pack(fmt"other:{GITHUB_EVENT_NAME}")

  if GITHUB_ACTOR != "":
    result["BUILD_CONTACT"] = pack(@[GITHUB_ACTOR])

registerPlugin("ci_github", GithubCI())
