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
  let
    args  = ctx.newCmdLine
    exe   = getDockerExeLocation()
    stdin = ctx.newStdIn
  trace("docker: " & exe & " " & args.join(" "))
  if stdin != "":
    trace("docker: stdin: \n" & stdin)
  result = runCmdNoOutputCapture(exe, args, stdin)

proc getUsableDockerContexts*(ctx: DockerInvocation): seq[string] =
  ## Returns local folders that chalk plugins can scan for metadata.
  ## For git contexts this is the raw .git directory, which allows plugins
  ## such as the git plugin to extract commit IDs and other VCS metadata.
  ## Stdin ("-"), remote URLs (containing ":"), and unresolvable paths are
  ## skipped with a warning.
  ## See also getLocalDockerContexts, which returns the user-code directories
  ## (work trees) used for file traversal and build-context upload.
  result = @[]
  let mainContext =
    if ctx.gitContext != nil: ctx.gitContext.tmpGitDir
    elif ctx.foundContext != "": ctx.foundContext
    else: ""
  if mainContext != "":
    if mainContext == "-":
      warn("docker: currently cannot use contexts passed via stdin.")
    elif ':' in mainContext:
      warn("docker: cannot use remote context: " & mainContext & " (skipping)")
    else:
      try:
        discard mainContext.resolvePath().getFileInfo()
        result.add(mainContext)
      except:
        warn("docker: cannot find context directory for chalking: " & mainContext)
  if ctx.foundExtraContexts != nil:
    for k, v in ctx.foundExtraContexts:
      if v == "-":
        warn("docker: currently cannot use contexts passed via stdin.")
        continue
      if ':' in v:
        warn("docker: cannot use remote context: " & v & " (skipping)")
        continue
      try:
        discard v.resolvePath().getFileInfo()
        result.add(v)
      except:
        warn("docker: cannot find context directory for chalking: " & v)
        continue

proc getLocalDockerContexts*(ctx: DockerInvocation): TableRef[string, string] =
  ## Returns local directory build contexts as name -> path, for upload or
  ## file traversal.  Git URL contexts are excluded entirely: their content
  ## is already captured in git state, so uploading would be redundant.
  ## The primary use-case is uploading contexts that may have been mutated
  ## relative to git (local directories).  Non-directory contexts (stdin,
  ## oci-layout://, docker-image://, etc.) are also skipped.
  ## See also getUsableDockerContexts, which returns raw .git dirs for plugin scanning.
  result = newTable[string, string]()
  # Git contexts are skipped: the content is already captured in git state.
  # Only local directory contexts (mutated relative to git) are worth uploading.
  if ctx.gitContext == nil and ctx.foundContext != "" and
      ctx.foundContext != "-" and ':' notin ctx.foundContext:
    try:
      let path = resolvePath(ctx.foundContext)
      if dirExists(path):
        result["."] = path
    except:
      warn("docker: cannot resolve context path: " & ctx.foundContext)
      dumpExOnDebug()
  if ctx.foundExtraContexts != nil:
    for name, path in ctx.foundExtraContexts:
      try:
        let resolved = resolvePath(path)
        if dirExists(resolved):
          result[name] = resolved
      except:
        warn("docker: cannot resolve extra context path '" & name & "': " & path)
        dumpExOnDebug()

proc isMultiPlatform*(ctx: DockerInvocation): bool =
  return len(ctx.foundPlatforms) > 1

proc onlyPlatform*(ctx: DockerInvocation): DockerPlatform =
  if len(ctx.foundPlatforms) > 1:
    raise newException(ValueError, "this is a multi-platform build")
  elif len(ctx.foundPlatforms) == 0:
    raise newException(ValueError, "did not find any build platforms")
  return ctx.foundPlatforms[0]

proc getAllBuildArgs*(ctx: DockerInvocation): Table[string, string] =
  ## get all build args (manually passed ones and system defaults)
  ## docker automatically assings some args for buildx build
  ## so we add them to the manually passed args which is necessary
  ## to correctly eval dockerfile to potentially resolve base image
  result = initTable[string, string]()
  for k, v in ctx.foundBuildArgs:
    result[k] = v
  for k, v in dockerProbeDefaultPlatforms():
    for n, a in v.args(k):
      result[n] = a

proc getSecret*(ctx: DockerInvocation, name: string): DockerSecret =
  let empty = DockerSecret(id: "", src: "")
  return ctx.foundSecrets.getOrDefault(name, empty)
