##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[config, collect, util]
import "."/[base, collect, scan]

proc dockerPush*(ctx: DockerInvocation): int =
  ctx.newCmdLine = ctx.originalArgs

  let chalkOpt = scanLocalImage(ctx.foundImage)

  if chalkOpt.isNone():
    error("docker: " & ctx.foundImage & " is not found. pushing without chalk")
    return setExitCode(ctx.runMungedDockerInvocation())

  # force DOCKER_PLATFORM to be included in chalk normalization
  # which is required to compute unique METADATA_* keys
  forceChalkKeys(["DOCKER_PLATFORM"])

  let chalk = chalkOpt.get()
  if not chalk.isChalked():
    warn("docker: " & chalk.name & " is not chalked. reporting will be limited")
    # these plugins are responsible for "inserting" new chalks
    # so they create things like CHALK_ID, METADATA_ID
    # but we just want to report keys about the artifact
    # without "creating" new chalkmark so we chalk-time collection
    suspendChalkCollectionFor("attestation")
    suspendChalkCollectionFor("docker")

  initCollection()
  chalk.addToAllChalks()
  chalk.collectChalkTimeArtifactInfo()

  result = setExitCode(ctx.runMungedDockerInvocation())

  chalk.collectLocalImage() # refetch repo tags/digests
  chalk.collectRunTimeArtifactInfo()
  collectRunTimeHostInfo()
