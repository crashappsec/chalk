##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  collect,
  run_management,
  types,
  utils/exec,
]
import "."/[
  base,
  scan,
]

proc dockerPull*(ctx: DockerInvocation): int =
  ctx.newCmdLine = ctx.originalArgs

  result = setExitCode(ctx.runMungedDockerInvocation())

  let chalkOpt = scanImage(ctx.foundImage, fromManifest = false)
  if chalkOpt.isNone():
    error("docker: " & ctx.foundImage & " cannot be collected")
    return

  let chalk = chalkOpt.get()
  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("docker: " & chalk.name & " is not chalked. reporting will be limited")
    initCollection()
    chalk.addToAllChalks()
    chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("pull")
    chalk.collectChalkTimeArtifactInfo()
    chalk.collectRunTimeArtifactInfo()
    collectRunTimeHostInfo()
