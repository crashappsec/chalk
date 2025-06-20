##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import pkg/[
  nimutils,
]

proc runCmdNoOutputCapture*(exe:       string,
                            args:      seq[string],
                            newStdIn = ""): int {.discardable.} =
  let execOutput = runCmdGetEverything(exe,
                                       args,
                                       newStdIn,
                                       passthrough = true,
                                       capture     = SPIoNone,
                                       timeoutUsec = 0) # No timeout
  result = execOutput.getExit()
