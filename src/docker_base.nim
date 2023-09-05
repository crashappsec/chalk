## Common docker-specific utility bits used in various parts of the
## implementation.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import osproc, config, util

var
  buildXVersion: float  = 0   # Major and minor only

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
    var
      userPath: seq[string]
      exeOpt   = chalkConfig.getDockerExe()

    if exeOpt.isSome():
      userPath.add(exeOpt.get())

    dockerPathOpt     = findExePath("docker", userPath, ignoreChalkExes = true)
    dockerExeLocation = dockerPathOpt.get("")

    if dockerExeLocation == "":
       warn("No docker command found in path. `chalk docker` not available.")

proc getBuildXVersion*(): float =
  # Have to parse the thing to get compares right.
  once:
    if getEnv("DOCKER_BUILDKIT") == "0":
      return 0
    let (output, exitcode) = execCmdEx(dockerExeLocation & " buildx version")
    if exitcode == 0:
      let parts = output.split(' ')
      if len(parts) >= 2 and len(parts[1]) > 1 and parts[1][0] == 'v':
        let vparts = parts[1][1 .. ^1].split('.')
        if len(vparts) > 1:
          let majorMinorStr = vparts[0] & "." & vparts[1]
          try:
            buildXVersion = parseFloat(majorMinorStr)
          except:
            dumpExOnDebug()

  return buildXVersion

template haveBuildContextFlag*(): bool =
  buildXVersion >= 0.8

proc runDockerGetOutput*(args: seq[string]): string =
  trace("Running: " & dockerExeLocation & " " & args.join(" "))
  return runCmdGetOutput(dockerExeLocation, args = args)

template runDockerGetEverything*(args: seq[string], stdin = ""): ExecOutput =
  runCmdGetEverything(dockerExeLocation, args, stdin)

var contextCounter = 0

proc makeFileAvailableToDocker*(ctx:      DockerInvocation,
                                inLoc:    string,
                                move:     bool,
                                chmod:    bool = false,
                                newName = "") =
  var loc         = inLoc.resolvePath()
  let (dir, file) = loc.splitPath()

  if move:
    trace("Making file available to docker via move: " & loc)
  else:
    trace("Making file available to docker via copy: " & loc)

  if haveBuildContextFlag():
    once:
      trace("Docker injection method: --build-context")

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add("chalkexedir" & $(contextCounter) & "=\"" & dir & "\"")
    ctx.addedInstructions.add("COPY --from=chalkexedir" & $(contextCounter) &
      " " & file & " /" & newname)
    if chmod:
      ctx.addedInstructions.add("RUN chmod 0755 /" & newname)
    contextCounter += 1
    if move:
      registerTempFile(loc)
  elif ctx.foundContext == "-":
    warn("Cannot chalk when context is passed to stdin w/o BUILDKIT support")
    raise newException(ValueError, "stdinctx")
  else:
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

        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
        if chmod:
          ctx.addedInstructions.add("RUN chmod 0755 /" & newname)

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

proc getAllDockerContexts*(info: DockerInvocation): seq[string] =
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
    allInfo = runDockerGetEverything(@["images", "--format", "json"])
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
