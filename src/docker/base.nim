##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common docker-specific utility bits used in various parts of the
## implementation.

import "../commands"/[cmd_help]
import ".."/[config, util, reporting]
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
