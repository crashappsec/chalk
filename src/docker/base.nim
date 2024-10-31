##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common docker-specific utility bits used in various parts of the
## implementation.

import ".."/[
  commands/cmd_help,
  n00b/subproc,
  reporting,
  types,
  utils/exec,
  utils/files,
  utils/subproc,
]
import "."/[
  exe,
  ids,
  platform,
]

proc dockerFailsafe*(ctx: DockerInvocation) {.noreturn.} =
  # If our mundged docker invocation fails, then we conservatively
  # assume we made some big mistake, and run Docker the way it
  # was originally called.
  var exitCode = 1
  try:
    let
      exe      = getDockerExeLocation()
      # even if docker is not found call subprocess with valid command name
      # so that we can bubble up error from subprocess
      docker   = if exe != "": exe else: "docker"
    exitCode = runCmdNoOutputCapture(docker,
                                     ctx.originalArgs,
                                     ctx.originalStdIn)
    setExitCode(exitCode)
    doReporting("fail")
    showConfigValues()
  finally:
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
    setExitCode(exitCode)
    if attrGet[bool]("docker.report_unwrapped_commands"):
      reporting.doReporting("report")
  except:
    dumpExOnDebug()
    doReporting("fail")
    showConfigValues()
  finally:
    quitChalk(exitCode)

proc runMungedDockerInvocation*(ctx: DockerInvocation): int =
  result = runCommand(
    getDockerExeLocation(),
    ctx.newCmdLine,
    stdin   = ctx.newStdIn,
    capture = {},
    proxy   = {StdAllFD},
    verbose = true,
  ).exitCode

proc getAllDockerContexts*(ctx: DockerInvocation): seq[string] =
  result = @[]
  if ctx.gitContext != nil:
    result.add(ctx.gitContext.tmpGitDir)
  else:
    if ctx.foundContext != "" and ctx.foundContext != "-":
      result.add(resolvePath(ctx.foundContext))
  for k, v in ctx.foundExtraContexts:
    result.add(resolvePath(v))

proc getUsableDockerContexts*(ctx: DockerInvocation): seq[string] =
  result = @[]
  for context in ctx.getAllDockerContexts():
    if context == "-":
      warn("docker: currently cannot use contexts passed via stdin.")
      continue
    if ':' in context:
      warn("docker: cannot use remote context: " & context & " (skipping)")
      continue
    try:
      discard context.resolvePath().getFileInfo()
      result.add(context)
    except:
      warn("docker: cannot find context directory for chalking: " & context)
      continue

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

proc getSecret*(ctx: DockerInvocation, name: string): DockerSecret =
  let empty = DockerSecret(id: "", src: "")
  return ctx.foundSecrets.getOrDefault(name, empty)
