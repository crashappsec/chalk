##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Dockerfile wrapping logic

import std/[sequtils]
import ".."/[config, selfextract]
import "."/[dockerfile, platform, exe, ids, image]

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
    hasUser       = user != "" and user != "root" and user != "0"

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

  if ctx.supportsBuildContextFlag():
    once:
      trace("docker: injection method: --build-context")

    let
      context = "chalkcontext" & $contextCounter
      ignore  = dir.joinPath(".dockerignore")
      shift   = ignore.fileExists()
      folder  = if shift: getNewTempDir() else: dir
      dstLoc  = folder.joinPath(file)

    if move:
      registerTempFile(loc)

    if shift:
      if move:
        trace("docker: .dockerignore is present in context. moving to tmp " & dstLoc)
        moveFile(loc, dstLoc)
      else:
        trace("docker: .dockerignore is present in context. copying to tmp " & dstLoc)
        copyFile(loc, dstLoc)

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add(context & "=" & folder)
    toAdd.add("COPY " &
              chmodstr &
              "--from=" & context & " " &
              file & " " & newPath)
    contextCounter += 1

  elif ctx.foundContext == "-":
    raise newException(
      ValueError,
      "Cannot chalk when context is passed to stdin w/o BUILDKIT support",
    )

  else:
    once:
      trace("docker: injection method: COPY")

    let contextDir = ctx.foundContext.resolvePath()
    # using extension which is unlikely to be already ignored by .dockerignore
    # by default temporary files use .tmp extension which might be ignored
    # whereas chalk is a lot less likely
    var dstLoc     = contextDir.joinPath(file & ".chalk")

    trace("docker: context directory is: " & contextDir)
    if not dirExists(contextDir):
      raise newException(
        ValueError,
        "Cannot find context directory (" & contextDir & ")"
      )

    try:
      while dirExists(dstLoc) or fileExists(dstLoc):
        dstLoc &= ".chalk"
      if move:
        moveFile(loc, dstLoc)
        trace("docker: moved " & loc & " to " & dstLoc)
      else:
        copyFile(loc, dstLoc)
        trace("docker: copied " & loc & " to " & dstLoc)
      registerTempFile(dstLoc)
      let (_, name) = dstLoc.splitPath()

      if supportsMultiStageBuilds():
        let base = "chalk" & newPath.replace("/", "_").replace(".", "_")
        toAdd.add("COPY --from=" & base & " " & newPath & " " & newPath)
        ctx.addedPlatform[base] = @[
          "FROM busybox AS " & base,
          "COPY " & name & " " & newPath,
          "RUN chmod " & chmod & " " & newPath,
        ]
      else:
        # NOTE this can fail as we have no guarantee that
        # RUN will work (e.g. distroless images) but we are out of
        # options at this point as:
        # * there is no buildx
        # * docker is older version which doesnt support multi-stage builds
        # and so we try our best but we cant pull a rabbit out of a hat...
        if chmodstr != "" and supportsCopyChmod():
          toAdd.add("COPY " & chmodstr & name & " " & newPath)
        elif chmod != "":
          if hasUser:
            toAdd.add("USER root")
          toAdd.add("COPY " & name & " " & newPath)
          toAdd.add("RUN chmod " & chmod & " " & newPath)
          if hasUser:
            toAdd.add("USER " & user)
        else:
          toAdd.add("COPY " & name & " " & newPath)

    except:
      dumpExOnDebug()
      raise newException(
        ValueError,
        "Could not write to context directory (" & dstLoc & "): " & getCurrentExceptionMsg(),
      )

proc addByPlatform(ctx: DockerInvocation, newPath: string, image = "scratch"): string =
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
    base = "chalk" & newPath.replace("/", "_").replace(".", "_")
    env  = "/$TARGETPLATFORM"
    arg  = "ARG TARGETPLATFORM"
    copy = "COPY --from=" & base & " " & env & " " & newPath
  if base notin ctx.addedPlatform:
    ctx.addedPlatform[base] = @["FROM " & image & " AS " & base]
  if arg notin ctx.addedInstructions:
    ctx.addedInstructions.add(arg)
  if copy notin ctx.addedInstructions:
    ctx.addedInstructions.add(copy)
  return base

proc makeFileAvailableToDocker*(ctx:        DockerInvocation,
                                path:       string,
                                newPath:    string,
                                user:       string,
                                move:       bool           = true,
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform) =
  if byPlatform:
    if not ctx.supportsBuildContextFlag():
      raise newException(
        ValueError,
        "recent version of buildx is required for copying files by platform into Dockerfile",
      )
    ctx.makeFileAvailableToDocker(
      path    = path,
      newPath = "/" & $platform.normalize(),
      user    = user,
      move    = move,
      chmod   = chmod,
      toAdd   = ctx.addedPlatform[ctx.addByPlatform(newPath)],
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
                                chmod:      string         = "",
                                byPlatform: bool           = false,
                                platform:   DockerPlatform = DockerPlatform(nil)) =
  # We are going to move this file, so don't autoclean.
  let path = writeNewTempFile(text, autoClean = false)
  ctx.makeFileAvailableToDocker(
    path       = path,
    newPath    = newPath,
    user       = user,
    move       = true, # cleanup file after build
    chmod      = chmod,
    byPlatform = byPlatform,
    platform   = platform,
  )

proc makeChalkAvailableToDocker*(ctx:      DockerInvocation,
                                 binaries: TableRef[DockerPlatform, string],
                                 newPath:  string  = "/chalk",
                                 user:     string,
                                 move:     bool,
                                 chmod:    string  = "0755") =
  let
    system = getSystemBuildPlatform()
    first  = binaries.keys().toSeq()[0]
  # even if not multi-platform, when target platform doesnt match
  # system platform we have to ensure copied chalk has identical configs
  if len(binaries) > 1 or first != system:
    if not ctx.supportsBuildContextFlag():
      raise newException(
        ValueError,
        "recent version of buildx is required for copying chalk by platform into Dockerfile",
      )
    let
      validate  = get[bool](getChalkScope(), "load.validate_configs_on_load")
      binfmt    = get[bool](getChalkScope(), "docker.install_binfmt")
      # other chalks might have different config for validate_configs_on_load
      # so we ensure we honor self config via CLI arg
      check     = if validate: "--validation" else: "--no-validation"
      config    = writeNewTempFile(getAllDumpJson())
      base      = ctx.addByPlatform(newPath, image = "busybox")
      log_level = getLogLevel()
      verbosity = if log_level == llTrace: "trace" else: "error"
    ctx.makeFileAvailableToDocker(
      path    = config,
      newPath = "/config.json",
      user    = user,
      move    = move,
      chmod   = "0444",
      toAdd   = ctx.addedPlatform[base],
    )
    for platform, path in binaries:
      # ensure platform is supported by the builder as chalk adds RUN commands
      # to dockerfile and if binfmt is not installed, multi-platform build might fail
      # where original dockerfile might not have any RUN commands which would
      # succeed the build otherwise
      if not ctx.doesBuilderSupportPlatform(platform):
        if binfmt:
          installBinFmt()
        else:
          raise newException(
            ValueError,
            "No support for " & $platform & " was detected in buildx builder. " &
            "To automatically add support via QEMU enable 'docker.install_binfmt' configuration. " &
            "Alternatively manually install binfmt as per " &
            "https://docs.docker.com/build/building/multi-platform/#qemu-without-docker-desktop"
          )
      info("docker: wrapping image with this chalk binary: " & path & " (" & $platform & ")")
      ctx.makeFileAvailableToDocker(
        path    = path,
        newPath = "/" & $platform.normalize(),
        user    = user,
        move    = move,
        chmod   = chmod,
        toAdd   = ctx.addedPlatform[base],
      )
    ctx.addedPlatform[base] &= @[
     "ARG TARGETPLATFORM",
     ("RUN /$TARGETPLATFORM load /config.json " &
      "--log-level=" & verbosity & " " &
      "--skip-command-report " &
      "--skip-custom-reports " &
      "--skip-summary-report " &
      "--replace " &
      "--all " &
      check),
     # sanity check plus it will show chalk metadata in build logs
     ("RUN /$TARGETPLATFORM version " &
      "--log-level=" & verbosity & " " &
      "--skip-command-report " &
      "--skip-custom-reports " &
      "--skip-summary-report"),
    ]
  else:
    for _, path in binaries:
      ctx.makeFileAvailableToDocker(
        path    = path,
        newPath = newPath,
        user    = user,
        move    = move,
        chmod   = chmod,
        toAdd   = ctx.addedInstructions,
      )
