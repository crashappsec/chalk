##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## utilities for interacting with docker images

import ".."/[config]
import "."/[exe]

proc pullImage*(name: string) =
  ## utility function for pull docker image to local daemon
  trace("docker: pulling " & name)
  let
    args   = @["pull", name]
    output = runDockerGetEverything(args)
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()
  if output.getExit() != 0:
    raise newException(
      ValueError,
      "cannot pull " & name & " due to: " &
      stdout & " " & stderr,
    )
