##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common docker-specific utility bits used in various parts of the
## implementation.

import "../commands"/[cmd_help]
import ".."/[config, util, reporting, semver]
import "."/[exe, ids, platform]

proc dockerFailsafe*(ctx: DockerInvocation) {.noreturn.} =
  # If our mundged docker invocation fails, then we conservatively
  # assume we made some big mistake, and run Docker the way it
  # was originally called.
  let
    exe      = getDockerExeLocation()
    # even if docker is not found call subprocess with valid command name
    # so that we can bubble up error from subprocess
    docker   = if exe != "": exe else: "docker"
    exitCode = runCmdNoOutputCapture(docker,
                                     ctx.originalArgs,
                                     ctx.originalStdIn)
  doReporting("fail")
  showConfigValues()
  quitChalk(exitCode)

template withDockerFailsafe*(ctx: DockerInvocation, code: untyped) =
  try:
    code
  except:
    error("docker: retrying without chalk due to: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    ctx.dockerFailsafe()

proc dockerPassThrough*(ctx: DockerInvocation) {.noreturn.} =
  # Silently pass through other docker commands right now.
  var exitCode = 1
  try:
    let exe = getDockerExeLocation()
    exitCode = runCmdNoOutputCapture(exe,
                                     ctx.originalArgs,
                                     ctx.originalStdIn)
    if get[bool](chalkConfig, "docker.report_unwrapped_commands"):
      reporting.doReporting("report")
    quitChalk(exitCode)
  except:
    dumpExOnDebug()
    doReporting("fail")
    showConfigValues()
    quitChalk(exitCode)

proc runMungedDockerInvocation*(ctx: DockerInvocation): int =
  let
    args  = ctx.newCmdLine
    exe   = getDockerExeLocation()
    stdin = ctx.newStdIn
  trace("docker: " & exe & " " & args.join(" "))
  if stdin != "":
    trace("docker: stdin: \n" & stdin)
  result = runCmdNoOutputCapture(exe, args, stdin)

var contextCounter = 0
proc makeFileAvailableToDocker(ctx:        DockerInvocation,
                               path:       string,
                               newPath:    string,
                               move:       bool,
                               chmod:      string,
                               toAdd:      var seq[string]) =
  var
    chmod         = chmod
  let
    loc           = path.resolvePath()
    (dir, file)   = loc.splitPath()
    userDirective = ctx.dfSections[^1].lastUser
    hasUser       = userDirective != nil

  # if USER directive is present and --chmod is not requested
  # default container user will not have access to the copied file
  # hence we default permission to read-only for all users
  if hasUser and chmod == "":
    chmod = "0444"

  let chmodstr =
    if chmod == "":
      ""
    else:
      "--chmod=" & chmod & " "

  if move:
    trace("docker: making file available to docker via move: " & loc & " @ " & newPath)
  else:
    trace("docker: making file available to docker via copy: " & loc & " @ " & newPath)

  if supportsBuildContextFlag():
    once:
      trace("docker: injection method: --build-context")

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add("chalkexedir" & $(contextCounter) & "=" & dir)
    toAdd.add("COPY " &
              chmodstr &
              "--from=chalkexedir" & $(contextCounter) &
              " " & file & " " & newPath)
    contextCounter += 1
    if move:
      registerTempFile(loc)

  elif ctx.foundContext == "-":
    raise newException(
      ValueError,
      "Cannot chalk when context is passed to stdin w/o BUILDKIT support",
    )

  else:
    once:
      trace("docker: injection method: COPY")

    let contextDir = ctx.foundContext.resolvePath()
    var dstLoc     = contextDir.joinPath(file)

    trace("docker: context directory is: " & contextDir)
    if not dirExists(contextDir):
      raise newException(
        ValueError,
        "Cannot find context directory (" & contextDir & ")"
      )

    try:
      if move:
        moveFile(loc, dstLoc)
        trace("docker: moved " & loc & " to " & dstLoc)
      else:
        while fileExists(dstLoc):
          dstLoc &= ".tmp"
        copyFile(loc, dstLoc)
        trace("docker: copied " & loc & " to " & dstLoc)

      if chmodstr != "" and supportsCopyChmod():
        toAdd.add("COPY " & chmodstr & file & " " & newPath)
      elif chmod != "":
        # TODO detect user from base image if possible but thats not
        # trivial as what is a base image is not a trivial question
        # due to multi-stage build possibilities...
        if hasUser:
          toAdd.add("USER root")
        toAdd.add("COPY " & file & " " & newPath)
        toAdd.add("RUN chmod " & chmod & " " & newPath)
        if hasUser:
          toAdd.add("USER " & userDirective.str)
      else:
        toAdd.add("COPY " & file & " " & newPath)
      registerTempFile(dstLoc)

    except:
      dumpExOnDebug()
      raise newException(
        ValueError,
        "Could not write to context directory (" & dstLoc & ").",
      )

proc makeFileAvailableToDocker*(ctx:        DockerInvocation,
                                path:       string,
                                newPath:    string,
                                move:       bool           = true,
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform = DockerPlatform(nil)) =
  if byPlatform:
    # in order to copy file by platform, we need to create
    # an intermediate build where the file path contains
    # the build platform which will allow us to COPY
    # that file into final image by referencing $TARGETPLATFORM
    # build arg hence customizing the file by platform.
    # for example:
    # FROM scratch as chalk_base
    # COPY foo /linux/amd64
    # COPY bar /linux/arm64
    # FROM alpine
    # ARG TARGETPLATFORM
    # COPY --from=chalk_base /$TARGETPLATFORM /chalk.json
    let
      platformBase = "chalk" & newPath.replace("/", "_").replace(".", "_")
      platformPath = "/" & $platform
      platformEnv  = "/$TARGETPLATFORM"
      platformArg  = "ARG TARGETPLATFORM"
    if platformBase notin ctx.addedPlatform:
      ctx.addedPlatform[platformBase] = @["FROM scratch AS " & platformBase]
    if platformArg notin ctx.addedInstructions:
      ctx.addedInstructions.add("ARG TARGETPLATFORM")
    ctx.addedInstructions.add("COPY --from=" & platformBase & " " & platformEnv & " " & newPath)
    ctx.makeFileAvailableToDocker(
      path = path,
      newPath = platformPath,
      move = move,
      chmod = chmod,
      toAdd = ctx.addedPlatform[platformBase],
    )
  else:
    ctx.makeFileAvailableToDocker(
      path = path,
      newPath = newPath,
      move = move,
      chmod = chmod,
      toAdd = ctx.addedInstructions,
    )

proc makeTextAvailableToDocker*(ctx:        DockerInvocation,
                                text:       string,
                                newPath:    string,
                                move:       bool           = true,
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform = DockerPlatform(nil)) =
  # We are going to move this file, so don't autoclean.
  let path = writeNewTempFile(text, autoClean = false)
  ctx.makeFileAvailableToDocker(
    path       = path,
    newPath    = newPath,
    move       = move,
    chmod      = chmod,
    byPlatform = byPlatform,
    platform   = platform,
  )

proc getAllDockerContexts*(ctx: DockerInvocation): seq[string] =
  result = @[]
  if ctx.gitContext != nil:
    result.add(ctx.gitContext.tmpGitDir)
  else:
    if ctx.foundContext != "" and ctx.foundContext != "-":
      result.add(resolvePath(ctx.foundContext))
  for k, v in ctx.foundExtraContexts:
    result.add(resolvePath(v))

proc isMultiPlatform*(ctx: DockerInvocation): bool =
  return len(ctx.foundPlatforms) > 1

proc getAllBuildArgs*(ctx: DockerInvocation): Table[string, string] =
  ## get all build args (manually passed ones and system defaults)
  ## docker automatically assings some args for buildx build
  ## so we add them to the manually passed args which is necessary
  ## to correctly eval dockerfile to potentially resolve base image
  result = initTable[string, string]()
  for k, v in ctx.foundBuildArgs:
    result[k] = v
  for k, v in dockerProbeDefaultPlatforms():
    result[k] = $v

proc getValue*(secret: DockerSecret): string =
  if secret.src != "":
    return tryToLoadFile(secret.src)
  return ""

proc getSecret*(ctx: DockerInvocation, name: string): DockerSecret =
  let empty = DockerSecret(id: "", src: "")
  return ctx.foundSecrets.getOrDefault(name, empty)
