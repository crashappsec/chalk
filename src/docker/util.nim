##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  re,
  unicode,
]
import ".."/[
  types,
  utils/json,
  utils/strings,
]

proc isCI*(): bool =
  ## Return true when running inside a known CI environment.
  const ciEnvVars = [
    "CI",                     # generic (GitHub Actions, GitLab CI, CircleCI, Travis CI, etc.)
    "GITHUB_ACTIONS",         # GitHub Actions
    "GITLAB_CI",              # GitLab CI
    "JENKINS_URL",            # Jenkins
    "CIRCLECI",               # CircleCI
    "TRAVIS",                 # Travis CI
    "BUILDKITE",              # Buildkite
    "DRONE",                  # Drone CI
    "SEMAPHORE",              # Semaphore CI
    "TEAMCITY_VERSION",       # TeamCity
    "BITBUCKET_BUILD_NUMBER", # Bitbucket Pipelines
    "CODEBUILD_BUILD_ID",     # AWS CodeBuild
  ]
  for v in ciEnvVars:
    if getEnv(v) != "":
      return true
  return false

template withAtomicAdds*(ctx: DockerInvocation, code: untyped) =
  withAtomicVar(ctx.addedPlatform):
    withAtomicVar(ctx.addedInstructions):
      code

proc isValidEnvVarName*(s: string): bool =
  if len(s) == 0 or (s[0] >= '0' and s[0] <= '9'):
    return false

  for ch in s:
    if ch.isAlphaNumeric() or ch == '_':
      continue
    return false

  return true

var labelPrefix: string
proc formatLabelKey(s: string): string =
  once:
    labelPrefix = attrGet[string]("docker.label_prefix")

  result = labelPrefix

  if not labelPrefix.endsWith('.'):
    result &= "."

  result &= s

  result = result.toLowerAscii()
  result = result.replace("_", "-")
  result = result.replace("$", "_")

type SkipLabel = object of CatchableError

proc formatLabelValue(v: string): string =
  if unicode.strip(v).len() == 0:
    raise newException(SkipLabel, "empty label")
  if v.startsWith('"') and v[^1] == '"':
    if len(v) > 1:
      return v
    else:
      raise newException(SkipLabel, "empty label")
  else:
    return escapeJson(v)

proc formatLabel(name: string, value: string, prefix = ""): string =
  result &= prefix & formatLabelKey(name) & "=" & formatLabelValue(value)
  trace("docker: formatting label: " & result)

proc addLabelArg(self: var seq[string], name: string, value: string) =
  try:
    let label = formatLabel(name, value)
    self.add("--label")
    self.add(label)
  except SkipLabel:
    discard

proc addLabelCmd*(self: var seq[string], name: string, value: string, prefix = "LABEL ") =
  try:
    let label = formatLabel(name, value, prefix = prefix)
    self.add(label)
  except SkipLabel:
    discard

proc addLabelArgs*(self: var seq[string], labels: TableRef[string, string]) =
  for k, v in labels:
    self.addLabelArg(k, v)

proc addLabelArgs*(self: var seq[string], labels: ChalkDict) =
  for k, v in labels:
    self.addLabelArg(k, v.boxToJson())

proc addLabelCmds*(self: var seq[string], labels: TableRef[string, string]) =
  for k, v in labels:
    self.addLabelCmd(k, v)

proc addLabelCmds*(self: var seq[string], labels: ChalkDict) =
  for k, v in labels:
    self.addLabelCmd(k, v.boxToJson())

proc formatChalkExec*(args: JsonNode = newJArray()): string =
  var
    arr  = `%*`(["/chalk", "exec"])
    args =
      if args == nil or args == %(@[""]):
        newJArray()
      else:
        args
  if len(args) > 0:
    if unicode.strip(args[0].getStr()) == "":
      raise newException(
        ValueError,
        "invalid first element in " & $args &
        " - has to be valid executable command"
      )
    arr.add(`%`("--exec-command-name"))
    arr.add(args[0])
  arr.add(`%`("--"))
  if len(args) > 1:
    arr &= args[1..^1]
  return $(arr)

proc getChalkKey*(chalk: ChalkObj, key: string): string =
  if len(key) == 0:
    warn("docker: " & key & ": Invalid key; cannot use empty key-name.")
    return ""

  if key.startsWith("_"):
    raise newException(KeyError, "Invalid key; cannot use run-time keys, only chalk-time keys.")

  if key notin getContents(attrGetObject("keyspec")):
    raise newException(KeyError, "Invalid chalk key; Chalk key doesn't exist.")

  if key in hostInfo:
    return $(hostInfo[key])

  if key in chalk.collectedData:
    return $(chalk.collectedData[key])

  raise newException(KeyError, "key could not be collected")

proc applySubstitutions*(s: string, chalk: ChalkObj): string =
  var
    key   = ""
    inKey = false
  for c in s:
    if c == '{':
      if inKey:
        raise newException(ValueError, s & ": invalid format string. '{' is repeated without closing previous occurance")
      inKey = true
      key   = ""
      continue
    elif c == '}':
      if not inKey:
        raise newException(ValueError, s & ": invalid format string. '{' is occurring without matching '}'")
      inKey = false
      if key != "":
        result &= chalk.getChalkKey(key.toUpperAscii())
      continue
    if inKey:
      key.add(c)
    else:
      result.add(c)

proc getValue*(secret: DockerSecret): string =
  if secret.src != "":
    return tryToLoadFile(secret.src)
  return ""

iterator iterContextUploadRepos*(chalk: ChalkObj): DockerContextUploadConfig =
  ## Yields a fully-resolved DockerContextUploadConfig for each docker_push
  ## config that has docker_context_upload.enabled = true and at least one tag.
  for registryName in getChalkSubsections("docker.docker_registry"):
    let
      registrySection = "docker.docker_registry." & registryName
      registryUri     = attrGet[string](registrySection & ".uri").removeSuffix('/')
      registryEnabled = attrGet[bool](registrySection & ".enabled")
    if not registryEnabled:
      continue
    for pushName in getChalkSubsections(registrySection & ".docker_push"):
      let
        pushSection    = registrySection & ".docker_push." & pushName
        pushEnabled    = attrGet[bool](pushSection & ".enabled")
        pushTags       = attrGet[seq[string]](pushSection & ".tags")
        pushRepo       = attrGet[string](pushSection & ".repository").removePrefix('/')
        contextSection = pushSection & ".docker_context_upload"
      if not pushEnabled or len(pushTags) == 0:
        continue
      if not sectionExists(contextSection):
        continue
      let
        contextEnabled         = attrGet[bool](contextSection & ".enabled")
        rawStrategy            = attrGet[string](contextSection & ".strategy")
        strategy               = if rawStrategy != "auto": rawStrategy
                                 elif isCI():              "registry"
                                 else:                     "local"
        sizeThreshold          = int(attrGet[Con4mSize](contextSection & ".size_threshold"))
        maxFileSize            = int(attrGet[Con4mSize](contextSection & ".max_file_size"))
        additionalDockerignore = attrGet[seq[string]](contextSection & ".additional_dockerignore")
        honorDockerignore      = attrGet[bool](contextSection & ".honor_dockerignore")
      if not contextEnabled:
        continue
      yield DockerContextUploadConfig(
        registryUri:            registryUri,
        registryName:           registryName,
        pushName:               pushName,
        repoPath:               pushRepo,
        tags:                   pushTags,
        strategy:               strategy,
        sizeThreshold:          sizeThreshold,
        maxFileSize:            maxFileSize,
        additionalDockerignore: additionalDockerignore,
        honorDockerignore:      honorDockerignore,
      )

iterator iterPushTags*(chalk: ChalkObj): string =
  for registryName in getChalkSubsections("docker.docker_registry"):
    let
      registrySection = "docker.docker_registry." & registryName
      registryUri     = attrGet[string](registrySection & ".uri").removeSuffix('/')
      registryEnabled = attrGet[bool](registrySection & ".enabled")
    if not registryEnabled:
      continue
    for pushName in getChalkSubsections(registrySection & ".docker_push"):
      let
        pushSection = registrySection & ".docker_push." & pushName
        pushEnabled = attrGet[bool](pushSection & ".enabled")
        pushRepo    = attrGet[string](pushSection & ".repository").removePrefix('/')
        pushTags    = attrGet[seq[string]](pushSection & ".tags")
      if not pushEnabled:
        continue
      for tag in pushTags:
        try:
          let
            renderedTag = (
              tag.applySubstitutions(chalk)
              .replace(re"[^a-zA-Z0-9_.\-]", "-")
            )
            image = registryUri & "/" & pushRepo & ":" & renderedTag
          if renderedTag == "":
            continue
          yield image
        except:
          warn("docker: " & getCurrentExceptionMsg())
