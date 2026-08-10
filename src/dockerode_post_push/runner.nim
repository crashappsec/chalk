##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  posix,
  strutils,
  tempfiles,
]
import pkg/nimutils/[
  file,
  logging,
]
import ../utils/subproc

const
  dockerodeRegisterSource = staticRead("register.cjs")
  dockerodeRuntimeSource  = staticRead("runtime.cjs")

proc runDockerodeCommand*(command: string,
                          commandArgs: seq[string],
                          noExternalConfig: bool): int =
  ## Run one command with a private loader, restoring the process before return.
  let
    loaderDir          = createTempDir("chalk-dockerode-", "-loader")
    register           = loaderDir / "register.cjs"
    runtime            = loaderDir / "runtime.cjs"
    priorNodeOptions   = getEnv("NODE_OPTIONS")
    priorChalk         = getEnv("CHALK_DOCKERODE_CHALK")
    priorNoExternal    = getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
    hadNodeOptions     = existsEnv("NODE_OPTIONS")
    hadChalk           = existsEnv("CHALK_DOCKERODE_CHALK")
    hadNoExternal      = existsEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")

  try:
    discard chmod(cstring(loaderDir), Mode(0o700))
    writeFile(register, dockerodeRegisterSource)
    writeFile(runtime, dockerodeRuntimeSource)
    discard chmod(cstring(register), Mode(0o600))
    discard chmod(cstring(runtime), Mode(0o600))
    putEnv("NODE_OPTIONS", (priorNodeOptions & " --require=\"" & register & "\"").strip())
    putEnv("CHALK_DOCKERODE_CHALK", getMyAppPath())
    if noExternalConfig:
      putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "1")
    result = runCmdNoOutputCapture(command, commandArgs)
  finally:
    if hadNodeOptions:
      putEnv("NODE_OPTIONS", priorNodeOptions)
    else:
      delEnv("NODE_OPTIONS")
    if hadChalk:
      putEnv("CHALK_DOCKERODE_CHALK", priorChalk)
    else:
      delEnv("CHALK_DOCKERODE_CHALK")
    if hadNoExternal:
      putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", priorNoExternal)
    else:
      delEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
    try:
      removeDir(loaderDir)
    except:
      warn("dockerode_run: could not remove temporary loader directory")
