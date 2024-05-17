##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk docker` command logic.
##
## Whereas other commands use the `collect` module for their overall
## collection logic, docker is completely different, with two
## different paths where we do collection... chalk extraction, and
## when running docker.
##
## The bits in common to those two things are mainly handled in the
## docker Codec, or in chalk_base when more appropriate.
##
## The extract path still starts in `cmd_extract.nim`, which can even
## make its way into `collect.nim` if specific containers or images
## are requested on the command line.
##
## But when wrapping docker, this module does the bulk of the work and
## is responsible for all of the collection logic.

import "../docker"/[base, build, push, exe, cmdline]
import ".."/[config, reporting, util, commands/cmd_help]

proc runCmdDocker*(args: seq[string]) =
  var
    exitCode = 0
    ctx      = initDockerInvocation(args)
  dockerInvocation = ctx

  if getDockerExeLocation() == "":
    error("docker command is missing. chalk requires docker binary installed to wrap docker commands.")
    ctx.dockerFailSafe()

  ctx.withDockerFailsafe():
    case ctx.extractDockerCommand()
    of DockerCmd.build:
      info("Running docker build.")
      setCommandName("build")
      exitCode = ctx.dockerBuild()
    of DockerCmd.push:
      info("Running docker push.")
      setCommandName("push")
      exitCode = ctx.dockerPush()
    else:
      ctx.dockerPassThrough()

  try:
    if exitCode == 0:
      reporting.doReporting("report")
    showConfigValues()
  except:
    # ignore any errors reporting/etc as we need to ensure
    # exit with appropriate exitCode if docker command passed
    error("docker post-command: " & getCurrentExceptionMsg())

  quitChalk(exitCode)
