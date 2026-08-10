##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  collect,
  config,
  run_management,
  types,
  utils/exec,
  utils/json,
  utils/subproc,
]
import "."/[
  base,
  context_upload,
  exe,
  login,
  manifest,
  inspect,
  repo_digest,
  scan,
  util,
]

proc collectAfterSuccessfulPush(chalk: ChalkObj) =
  chalk.collectRunTimeArtifactInfo()
  if chalk.isChalked():
    cleanBuildContextCache()
    try:
      chalk.collectedData.merge(chalk.completeBuildContextUploads(
        source = chalk.extract,
      ))
    except:
      error("docker: build context attestation failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
  collectRunTimeHostInfo()
  flushAttestationTags()

proc dockerPostPush*(image, expectedDigest: string): bool =
  ## Collect and report the successful push performed by an SDK. This function
  ## never invokes `docker push`, including configured mirror pushes.
  let local = inspectImageJson(image)
  if not repoDigestMatches(image, expectedDigest, local{"RepoDigests"}.getStrElems()):
    error("docker: post-push digest does not match local RepoDigests for " & image)
    return false

  let chalkOpt = scanImage(image, fromManifest = false)
  if chalkOpt.isNone():
    error("docker: " & image & " is not found; post-push collection skipped")
    return false

  forceChalkKeys(["DOCKER_PLATFORM"])
  let chalk = chalkOpt.get()
  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("docker: " & chalk.name & " is not chalked. reporting will be limited")
      suspendChalkCollectionFor("attestation")
      suspendChalkCollectionFor("docker")

    loginToRegistries()
    initCollection()
    chalk.addToAllChalks()
    chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("push")
    chalk.collectChalkTimeArtifactInfo()
    chalk.collectAfterSuccessfulPush()
  return true

proc dockerPush*(ctx: DockerInvocation): int =
  ctx.newCmdLine = ctx.originalArgs

  let chalkOpt = scanImage(ctx.foundImage, fromManifest = false)
  if chalkOpt.isNone():
    error("docker: " & ctx.foundImage & " is not found. pushing without chalk")
    return setExitCode(ctx.runMungedDockerInvocation())

  # force DOCKER_PLATFORM to be included in chalk normalization
  # which is required to compute unique METADATA_* keys
  forceChalkKeys(["DOCKER_PLATFORM"])

  let chalk = chalkOpt.get()

  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("docker: " & chalk.name & " is not chalked. reporting will be limited")
      # these plugins are responsible for "inserting" new chalks
      # so they create things like CHALK_ID, METADATA_ID
      # but we just want to report keys about the artifact
      # without "creating" new chalkmark so we chalk-time collection
      suspendChalkCollectionFor("attestation")
      suspendChalkCollectionFor("docker")

    # login to any registries before any collection
    # as auth provided by auth might be required
    loginToRegistries()

    initCollection()
    chalk.addToAllChalks()
    chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("push")
    chalk.collectChalkTimeArtifactInfo()

    result = setExitCode(ctx.runMungedDockerInvocation())

    var imagesToPrune = newSeq[string]()
    if result == 0:
      for image in chalk.iterPushTags():
        trace("docker: pushing to - " & image)
        try:
          let retag = runDockerGetEverything(@["tag", chalk.name, image])
          if retag.exitCode != 0:
            error("docker: could not tag as " & image & ". ignoring error - " & retag.stderr)
            continue
          imagesToPrune.add(image)
        except:
          continue
        try:
          discard runCmdNoOutputCapture(getDockerExeLocation(), @["push", image])
        except:
          error("docker: could not push image " & image & ". ignoring error")

    try:
      if result == 0:
        chalk.collectAfterSuccessfulPush()
      else:
        chalk.collectRunTimeArtifactInfo()
        collectRunTimeHostInfo()
        flushAttestationTags()
    finally:
      for i in imagesToPrune:
        try:
          discard runDockerGetEverything(@["rmi", i])
        except:
          discard
