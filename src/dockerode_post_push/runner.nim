##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  strutils,
  tempfiles,
]
import pkg/nimutils/[
  file,
  logging,
]
import ../utils/[
  envvars,
  files,
  subproc,
]
import ./assets

proc runDockerodeCommand*(command: string,
                          commandArgs: seq[string],
                          noExternalConfig: bool): int =
  ## Run one foreground command tree with a private loader, restoring the process
  ## and removing the loader after the command returns. Instrumented descendants
  ## that outlive the wrapped command are outside this command's support boundary.
  let
    loaderDir          = createTempDir("chalk-dockerode-", "-loader")
    priorNodeOptions   = getEnv("NODE_OPTIONS")

  try:
    discard chmodFilePermissions(loaderDir, "0700")
    let register = writeDockerodeAssets(loaderDir, "0600")
    let envVars = @[
      setEnv("NODE_OPTIONS", (priorNodeOptions & " --require=\"" & register & "\"").strip()),
      setEnv("CHALK_DOCKERODE_CHALK", getMyAppPath()),
    ]
    withEnvRestore(envVars):
      if noExternalConfig:
        let noExternalConfigEnv = @[
          setEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "1"),
        ]
        withEnvRestore(noExternalConfigEnv):
          result = runCmdNoOutputCapture(command, commandArgs)
      else:
        result = runCmdNoOutputCapture(command, commandArgs)
  finally:
    try:
      removeDir(loaderDir)
    except:
      warn("dockerode: could not remove temporary loader directory")
