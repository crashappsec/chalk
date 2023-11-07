##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common docker-specific utility bits used in various parts of the
## implementation.

import uri, osproc, config, util, reporting, semver

var
  buildXVersion: Version = parseVersion("0")
  dockerVersion: Version = parseVersion("0")

const
  hashHeader* = "sha256:"

var dockerPathOpt: Option[string] = none(string)

template extractDockerHash*(value: string): string =
  if not value.startsWith(hashHeader):
    value
  else:
    value[len(hashHeader) .. ^1]

template extractBoxedDockerHash*(value: Box): Box =
  pack(extractDockerHash(unpack[string](value)))

proc setDockerExeLocation*() =
  once:
    trace("Searching path for 'docker'")
    dockerExeLocation = findExePath("docker",
                                    configPath = chalkConfig.getDockerExe(),
                                    ignoreChalkExes = true).get("")

    if dockerExeLocation == "":
       warn("No docker command found in path. `chalk docker` not available.")

proc getVersionFromLine(line: string): Version =
  for word in line.splitWhitespace():
    if '.' in word:
      try:
        return parseVersion(word.strip(chars = {'v', ','}))
      except:
        # word wasnt a version number
        discard
  raise newException(ValueError, "no version found")

proc getBuildXVersion*(): Version =
  # Have to parse the thing to get compares right.
  once:
    if getEnv("DOCKER_BUILDKIT") == "0":
      return buildXVersion

    # examples:
    # github.com/docker/buildx v0.10.2 00ed17df6d20f3ca4553d45789264cdb78506e5f
    # github.com/docker/buildx 0.11.2 9872040b6626fb7d87ef7296fd5b832e8cc2ad17
    let (output, exitcode) = execCmdEx(dockerExeLocation & " buildx version")
    if exitcode == 0:
      try:
        buildXVersion = getVersionFromLine(output)
        trace("Docker buildx version: " & $(buildXVersion))
      except:
        dumpExOnDebug()

  return buildXVersion

proc getDockerVersion*(): Version =
  once:
    # examples:
    # Docker version 1.13.0, build 49bf474
    # Docker version 23.0.0, build e92dd87
    # Docker version 24.0.6, build ed223bc820
    let (output, exitcode) = execCmdEx(dockerExeLocation & " --version")
    if exitcode == 0:
      try:
        dockerVersion = getVersionFromLine(output)
        trace("Docker version: " & $(dockerVersion))
      except:
        dumpExOnDebug()

  return dockerVersion

template hasBuildx*(): bool =
  getBuildXVersion() > parseVersion("0")

template supportsBuildContextFlag*(): bool =
  getBuildXVersion() >= parseVersion("0.8")

template supportsCopyChmod*(): bool =
  # > the --chmod option requires BuildKit.
  # > Refer to https://docs.docker.com/go/buildkit/ to learn how to
  # > build images with BuildKit enabled
  hasBuildx()

proc runDockerGetEverything*(args: seq[string], stdin = "", silent = true): ExecOutput =
  if not silent:
    trace("Running docker: " & dockerExeLocation & " " & args.join(" "))
    if stdin != "":
      trace("Passing on stdin: \n" & stdin)
  result = runCmdGetEverything(dockerExeLocation, args, stdin)
  if not silent and result.exitCode > 0:
    trace(strutils.strip(result.stderr & result.stdout))
  return result

proc dockerFailsafe*(info: DockerInvocation) {.cdecl, exportc.} =
  # If our mundged docker invocation fails, then we conservatively
  # assume we made some big mistake, and run Docker the way it
  # was originally called.

  var newStdin = "" # Passthrough; either nothing or a build context

  # Here, a docker file was passed on stdin, and we have already
  # read it, so we need to put it back on stdin.
  if info.dockerFileLoc == ":stdin:":
    newStdin = info.inDockerFile

  let exitCode = runProcNoOutputCapture(dockerExeLocation,
                                        info.originalArgs,
                                        newStdin)
  doReporting("fail")
  quitChalk(exitCode)

var contextCounter = 0

proc makeFileAvailableToDocker*(ctx:      DockerInvocation,
                                inLoc:    string,
                                move:     bool,
                                chmod:    bool = false,
                                newName = "") =
  var loc         = inLoc.resolvePath()
  let
    (dir, file)   = loc.splitPath()
    userDirective = ctx.dfSections[^1].lastUser
    hasUser       = userDirective != nil

  if move:
    trace("Making file available to docker via move: " & loc)
  else:
    trace("Making file available to docker via copy: " & loc)

  if supportsBuildContextFlag():
    once:
      trace("Docker injection method: --build-context")

    var chmodstr = ""

    if chmod or hasUser:
      chmodstr = "--chmod=0755 "

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add("chalkexedir" & $(contextCounter) & "=" & dir & "")
    ctx.addedInstructions.add("COPY " & chmodstr & "--from=chalkexedir" &
      $(contextCounter) & " " & file & " /" & newname)
    contextCounter += 1
    if move:
      registerTempFile(loc)

  elif ctx.foundContext == "-":
    warn("Cannot chalk when context is passed to stdin w/o BUILDKIT support")
    raise newException(ValueError, "stdinctx")

  else:
    once:
      trace("Docker injection method: COPY")

    var
      contextDir  = ctx.foundContext.resolvePath()
      dstLoc      = contextDir.joinPath(file)

    trace("Context directory is: " & contextDir)
    if not dirExists(contextDir):
      warn("Cannot find context directory (" & contextDir &
        "), so cannot wrap entry point.")
      raise newException(ValueError, "ctxwrite")

    try:
      if move:
        moveFile(loc, dstLoc)
        trace("Moved " & loc & " to " & dstLoc)
      else:
        while fileExists(dstLoc):
          dstLoc &= ".tmp"
        copyFile(loc, dstLoc)
        trace("Copied " & loc & " to " & dstLoc)

      if chmod and supportsCopyChmod():
        ctx.addedInstructions.add("COPY --chmod=0755 " &
                                  file & " " & " /" & newname)
      elif chmod:
        # TODO detect user from base image if possible but thats not
        # trivial as what is a base image is not a trivial question
        # due to multi-stage build possibilities...
        if hasUser:
          ctx.addedInstructions.add("USER root")
        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
        ctx.addedInstructions.add("RUN chmod 0755 /" & newname)
        if hasUser:
          ctx.addedInstructions.add("USER " & userDirective.str)
      else:
        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
      registerTempFile(dstLoc)

    except:
      dumpExOnDebug()
      warn("Could not write to context directory.")
      raise newException(ValueError, "ctxcpy")

proc chooseNewTag*(): string =
  let
    randInt = secureRand[uint]()
    hexVal  = toHex(randInt and 0xffffffffffff'u).toLowerAscii()

  return "chalk-" & hexVal & ":latest"

proc parseTag*(tag: string): (string, string) =
  # parseUri requires some scheme to parse url correctly so we add dummy https
  # parsed uri will allow us to figure out if tag contains version
  # (note that tag can be full registry path which can include
  # port in the hostname)
  let uri = parseUri("https://" & tag)
  if ":" in uri.path:
    let
      tagParts = tag.rsplit(":", maxsplit = 1)
      name     = tagParts[0]
      version  = tagParts[1]
    return (name, version)
  else:
    return (tag, "latest")

proc getAllDockerContexts*(info: DockerInvocation): seq[string] =
  if info.gitContext != nil:
    result.add(info.gitContext.tmpGitDir)
  else:
    if info.foundContext != "" and info.foundContext != "-":
      result.add(resolvePath(info.foundContext))

  for k, v in info.otherContexts:
    result.add(resolvePath(v))

proc populateBasicImageInfo*(chalk: ChalkObj, info: JSonNode) =
  let
    repo  = info["Repository"].getStr()
    tag   = info["Tag"].getStr.replace("\u003cnone\u003e", "").strip()
    short = info["ID"].getStr()

  chalk.repo    = repo
  chalk.tag     = tag
  chalk.shortId = short

proc getBasicImageInfo*(refName: string): Option[JSonNode] =
  let
    allInfo = runDockerGetEverything(@["images", "--format", "{{json . }}"])
    stdout  = allInfo.getStdout().strip()

  if allInfo.getExit() != 0 or stdout == "":
    return none(JsonNode)

  let
    lines = stdout.split("\n")
    name  = refName.toLowerAscii()

  for line in lines:
    # Comparing line.strip() to "" or checking the length didn't work??
    # There might be some unprintable character before EOF in stdin.
    if not line.strip().startswith("{"):
      break
    let
      json = parseJson(line)
      repo = json["Repository"].getStr()
      tag  = json["Tag"].getStr().replace("\u003cnone\u003e", "")
      id   = json["ID"].getStr()

    if name.toLowerAscii() == id:
      return some(json)
    if name == repo:
      return some(json)
    if name == repo & ":" & tag:
      return some(json)

  return none(JsonNode)

proc extractBasicImageInfo*(chalk: ChalkObj): bool =
  # usreRef should always be what was passed on the command line, and
  # if nothing was passed on the command line, it will be our
  # temporary tag.
  let info = getBasicImageInfo(chalk.userRef)

  if info.isNone():
    return false

  chalk.populateBasicImageInfo(info.get())
  return true

proc dockerGenerateChalkId*(): string =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in b: preRes.add(ch)
  return preRes.idFormat()

proc getValue*(secret: DockerSecret): string =
  if secret.src != "":
    return tryToLoadFile(secret.src)
  return ""

proc getSecret*(state: DockerInvocation, name: string): DockerSecret =
  let empty = DockerSecret(id: "", src: "")
  return state.secrets.getOrDefault(name, empty)
