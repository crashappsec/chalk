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

when getEnv("CHALK_TYPESCRIPT_BUILT") != "1":
  {.fatal: "Dockerode TypeScript artifacts are unavailable or stale; run `make` (or `make transpile`) instead of `nimble build`.".}

const
  dockerodeRegisterSource     = staticRead("../../build/src/dockerode_post_push/register.cjs")
  dockerodeRegisterImplSource = staticRead("../../build/src/dockerode_post_push/register_impl.cjs")
  dockerodeRuntimeSource      = staticRead("../../build/src/dockerode_post_push/runtime.cjs")
  dockerodeNodeSupportSource  = staticRead("../../build/src/dockerode_post_push/node_support.cjs")

proc runDockerodeCommand*(command: string,
                          commandArgs: seq[string],
                          noExternalConfig: bool): int =
  ## Run one foreground command tree with a private loader, restoring the process
  ## and removing the loader after the command returns. Instrumented descendants
  ## that outlive the wrapped command are outside this command's support boundary.
  let
    loaderDir          = createTempDir("chalk-dockerode-", "-loader")
    register           = loaderDir / "register.cjs"
    registerImpl       = loaderDir / "register_impl.cjs"
    runtime            = loaderDir / "runtime.cjs"
    nodeSupport        = loaderDir / "node_support.cjs"
    priorNodeOptions   = getEnv("NODE_OPTIONS")

  try:
    discard chmodFilePermissions(loaderDir, "0700")
    writeFile(register, dockerodeRegisterSource)
    writeFile(registerImpl, dockerodeRegisterImplSource)
    writeFile(runtime, dockerodeRuntimeSource)
    writeFile(nodeSupport, dockerodeNodeSupportSource)
    for path in [register, registerImpl, runtime, nodeSupport]:
      discard chmodFilePermissions(path, "0600")
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
