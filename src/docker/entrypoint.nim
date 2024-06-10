##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Utilities for inspecting/fetching/wrapping dockerfile entrypoints

import ".."/[config]
import "."/[dockerfile, ids, image, wrap, util]

proc getTargetEntrypoints(ctx: DockerInvocation, platform: DockerPlatform): DockerEntrypoint =
  ## get entrypoints (entrypoint/cmd/shell) from the target section
  ## this recursively looks up parent sections in dockerfile
  ## and eventually looks up entrypoints in base image
  let
    base    = ctx.getBaseDockerSection()
  var
    entrypoint = base.entrypoint
    cmd        = base.cmd
    shell      = base.shell
  for s in ctx.getBaseDockerSections():
    if s.entrypoint != nil:
      entrypoint = s.entrypoint
      # defining entrypoint in image wipes any previous CMD
      # and it needs to be redefined again in Dockerfile
      cmd        = nil
    if s.cmd != nil:
      cmd        = s.cmd
    if s.shell != nil:
      shell      = s.shell
  # no more sections in Dockerfile and instead we need to
  # inspect the base image
  if entrypoint == nil or cmd == nil or shell == nil:
    let info = fetchImageEntrypoint(base.image, platform)
    # if entrypoint was defined somewhere in the dockerfile,
    # base image CMD is automatically ignored so only set
    # if entrypoint is missing
    if cmd == nil and entrypoint == nil:
      cmd        = info.cmd
    if entrypoint == nil:
      entrypoint = info.entrypoint
    if shell == nil:
      shell      = info.shell
  # default shell to /bin/sh so that we can wrap CMD shell-form correctly
  if shell == nil:
    shell = ShellInfo()
    shell.json = `%*`(["/bin/sh", "-c"])
  return (entrypoint, cmd, shell)

proc getCommonTargetEntrypoints*(ctx: DockerInvocation, platforms: seq[DockerPlatform]): DockerEntrypoint =
  result = ctx.getTargetEntrypoints(platforms[0])
  var previous = (platforms[0], result)
  for platform in platforms:
    let
      (pPlatform, pEntrypoints) = previous
      entrypoints = ctx.getTargetEntrypoints(platform)
    if entrypoints != pEntrypoints:
      raise newException(
        ValueError,
        "Base image ENTRYPOINT does not match between different platforms. " &
        $pPlatform & " " & $pEntrypoints & " != " & $platform & " " & $entrypoints
      )
    result   = entrypoints
    previous = (platform, entrypoints)

proc rewriteEntryPoint*(ctx:        DockerInvocation,
                        entrypoint: DockerEntrypoint,
                        binaries:   TableRef[DockerPlatform, string],
                        user:       string) =
  let
    fromArgs             = get[bool](chalkConfig, "exec.command_name_from_args")
    wrapCmd              = get[bool](chalkConfig, "docker.wrap_cmd")
    (entrypoint, cmd, _) = entrypoint

  if not fromArgs:
    raise newException(
      ValueError,
      "Docker wrapping requires exec.command_name_from_args config to be enabled"
    )

  if entrypoint == nil:
    if wrapCmd:
      if cmd == nil:
        raise newException(
          ValueError,
          "Cannot wrap; no ENTRYPOINT or CMD found in Dockerfile"
        )
      else:
        trace("docker: no ENTRYPOINT; Wrapping image CMD")
    else:
      if cmd != nil:
        raise newException(
          ValueError,
          "Cannot wrap; no ENTRYPOINT in Dockerfile but there is CMD. " &
          "To wrap CMD enable 'docker.wrap_cmd' config option"
        )
      else:
        raise newException(
          ValueError,
          "Cannot wrap; no ENTRYPOINT found in Dockerfile"
        )

  ctx.makeChalkAvailableToDocker(
      binaries = binaries,
      newPath  = "/chalk",
      user     = user,
      move     = false, # preserve original file
      chmod    = "0755",
  )

  var toAdd: seq[string] = @[]
  let hasUser = user != "" and user != "root"
  if hasUser:
    toAdd.add("ONBUILD USER root")
  toAdd.add("""ONBUILD RUN ["/chalk", "--no-use-embedded-config", "--no-use-external-config", "__", "onbuild"]""")
  if hasUser:
    toAdd.add("ONBUILD USER " & user)

  if entrypoint != nil:
    # When ENTRYPOINT is string, it is a shell script
    # in which case docker ignores CMD which means we can
    # change it without changing container semantics so we:
    # * convert ENTRYPOINT to JSON
    # * pass existing ENTRYPOINT as CMD string
    # this will then call chalk as entrypoint and
    # will pass SHELL + CMD as args to chalk
    if entrypoint.str != "":
      toAdd.add("ENTRYPOINT " & formatChalkExec())
      toAdd.add("CMD " & entrypoint.str)
    # When ENTRYPOINT is JSON, we wrap JSON with /chalk command
    # setting ENTRYPOINT however resets the CMD and so to be safe
    # we redefine CMD to guarantee its used
    else:
      toAdd.add("ENTRYPOINT " & formatChalkExec(entrypoint.json))
      if cmd != nil:
        toAdd.add("CMD " & $(cmd))
    trace("docker: ENTRYPOINT wrapped.")

  else:
    # When ENTRYPOINT is missing, we can use /chalk as ENTRYPOINT
    # which will then execute existing CMD whether it is in shell or json form
    # only nuance is that if CMD is not directly defined in target
    # Dockerfile section, defining ENTRYPOINT resets CMD to null
    # so to be safe we redefine CMD to the same value
    toAdd.add("ENTRYPOINT " & formatChalkExec())
    toAdd.add("CMD " & $(cmd))
    trace("docker: CMD wrapped with ENTRYPOINT.")

  ctx.addedInstructions &= toAdd
  trace("docker: added instructions:\n" & toAdd.join("\n"))
