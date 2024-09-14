##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

##
## chalk `daemon` command
##

import os, std/posix
import ".."/[config, util, reporting]

# this const is not available in nim stdlib hence manual c import
var TIOCNOTTY {.importc, header: "sys/ioctl.h"}: cuint

proc daemon() =
  while true:
    doReporting()
    sleep 5000

proc runCmdDaemon*() =
  let
    period = int(get[Con4mDuration](getChalkScope(), "daemon.period"))

  let pid = fork()
  if pid == -1:
    error("Could not spawn daemon process.")
    setExitCode(1)
  if pid != 0:
    quit()

  let is_err = setpgid(0, 0)
  if is_err == -1:
    setExitCode(1)
    error("Chalk couldn't reset the process group: $1" % [$strerror(errno)])
    quit()

  if isatty(0) != 0:
    let is_err = ioctl(0, TIOCNOTTY)
    if is_err == -1:
      setExitCode(1)
      error("Error on disconnecting from tty: $1" % [$strerror(errno)])

  # loop forever
  daemon()
