import std/os
import ../../src/docker/util

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

const ciVars = [
  "CI",
  "GITHUB_ACTIONS",
  "GITLAB_CI",
  "JENKINS_URL",
  "CIRCLECI",
  "TRAVIS",
  "BUILDKITE",
  "DRONE",
  "SEMAPHORE",
  "TEAMCITY_VERSION",
  "BITBUCKET_BUILD_NUMBER",
  "CODEBUILD_BUILD_ID",
]

proc withEnv(key, val: string, body: proc()) =
  let prev = getEnv(key)
  let hadPrev = existsEnv(key)
  putEnv(key, val)
  try:
    body()
  finally:
    if hadPrev:
      putEnv(key, prev)
    else:
      delEnv(key)

proc withoutEnv(key: string, body: proc()) =
  let prev = getEnv(key)
  let hadPrev = existsEnv(key)
  delEnv(key)
  try:
    body()
  finally:
    if hadPrev:
      putEnv(key, prev)

proc clearAllCiVars(body: proc()) =
  ## Run body with all known CI env vars unset.
  var saved: seq[(string, string, bool)]
  for v in ciVars:
    saved.add((v, getEnv(v), existsEnv(v)))
    delEnv(v)
  try:
    body()
  finally:
    for (k, val, had) in saved:
      if had:
        putEnv(k, val)
      else:
        delEnv(k)

proc main() =
  clearAllCiVars(proc() =
    ## No CI vars set: isCI must return false.
    check not isCI()

    ## Each individual CI variable must trigger isCI.
    for v in ciVars:
      withEnv(v, "true", proc() =
        check isCI()
      )

    ## Empty-string value must not trigger isCI.
    withEnv("CI", "", proc() =
      check not isCI()
    )
  )

main()
