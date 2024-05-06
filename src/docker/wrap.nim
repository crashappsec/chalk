##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Dockerfile wrapping logic

import ".."/[config, semver]
import "."/[dockerfile, exe, ids, image]

proc getTargetUser(ctx: DockerInvocation, platform: DockerPlatform): string =
  ## get USER from the target section
  ## this recursively looks up parent sections in dockerfile
  ## and eventually looks up in base image
  for section in ctx.getTargetDockerSections():
    if section.lastUser != nil:
      return section.lastUser.str
  let baseSection = ctx.getBaseDockerSection()
  return fetchImageUser(baseSection.image, platform)

proc getCommonTargetUser*(ctx: DockerInvocation, platforms: seq[DockerPlatform]): string =
  result = ctx.getTargetUser(platforms[0])
  var previous = (platforms[0], result)
  for platform in platforms:
    let
      (pPlatform, pUser) = previous
      user = ctx.getTargetUser(platform)
    if user != pUser:
      raise newException(
        ValueError,
        "Base image USER does not match between different platforms. " &
        $pPlatform & " " & pUser & " != " & $platform & " " & user
      )
    result   = user
    previous = (platform, user)

var contextCounter = 0
proc makeFileAvailableToDocker(ctx:        DockerInvocation,
                               path:       string,
                               newPath:    string,
                               user:       string,
                               move:       bool,
                               chmod:      string,
                               toAdd:      var seq[string]) =
  var
    chmod         = chmod
  let
    loc           = path.resolvePath()
    (dir, file)   = loc.splitPath()
    hasUser       = user != "" and user != "root"

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
          toAdd.add("USER " & user)
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
                                user:       string,
                                move:       bool           = true,
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform) =
  if byPlatform:
    if not supportsBuildContextFlag():
      raise newException(
        ValueError,
        "recent version of buildx is required for copying files by platform into Dockerfile",
      )
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
      platformCopy = "COPY --from=" & platformBase & " " & platformEnv & " " & newPath
    if platformBase notin ctx.addedPlatform:
      ctx.addedPlatform[platformBase] = @["FROM scratch AS " & platformBase]
    if platformArg notin ctx.addedInstructions:
      ctx.addedInstructions.add(platformArg)
    if platformCopy notin ctx.addedInstructions:
      ctx.addedInstructions.add(platformCopy)
    ctx.makeFileAvailableToDocker(
      path    = path,
      newPath = platformPath,
      user    = user,
      move    = move,
      chmod   = chmod,
      toAdd   = ctx.addedPlatform[platformBase],
    )
  else:
    ctx.makeFileAvailableToDocker(
      path    = path,
      newPath = newPath,
      user    = user,
      move    = move,
      chmod   = chmod,
      toAdd   = ctx.addedInstructions,
    )

proc makeTextAvailableToDocker*(ctx:        DockerInvocation,
                                text:       string,
                                newPath:    string,
                                user:       string,
                                move:       bool           = true,
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform = DockerPlatform(nil)) =
  # We are going to move this file, so don't autoclean.
  let path = writeNewTempFile(text, autoClean = false)
  ctx.makeFileAvailableToDocker(
    path       = path,
    newPath    = newPath,
    user       = user,
    move       = move,
    chmod      = chmod,
    byPlatform = byPlatform,
    platform   = platform,
  )
