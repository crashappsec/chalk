##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[config, collect, plugin_api]
import "."/[base, collect, scan]

proc dockerPush*(ctx: DockerInvocation): int =
  ctx.newCmdLine = ctx.originalArgs

  let
    codec    = getPluginByName("docker")
    chalkOpt = codec.scanImage(ctx.foundImage)

  if chalkOpt.isNone():
    error("docker: " & ctx.foundImage & " is not found. pushing without chalk")
    return ctx.runMungedDockerInvocation()

  let chalk = chalkOpt.get()
  if not chalk.isChalked():
    warn("docker: " & chalk.name & " is not chalked. reporting will be limited")
    # these plugins are responsible for "inserting" new chalks
    # so they create things like CHALK_ID, METADATA_ID
    # but we just want to report keys about the artifact
    # without "creating" new chalkmark so we chalk-time collection
    suspendChalkCollectionFor("metsys")
    suspendChalkCollectionFor("docker")

  initCollection()
  chalk.addToAllChalks()
  chalk.collectChalkTimeArtifactInfo()

  result = ctx.runMungedDockerInvocation()

  chalk.collectImage() # refetch repo tags/digests
  chalk.collectRunTimeArtifactInfo()
  collectRunTimeHostInfo()
