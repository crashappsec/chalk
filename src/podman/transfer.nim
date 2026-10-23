##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `podman push` and `podman pull` instrumentation.
##
## Structure mirrors dockerPush/dockerPull (src/docker/push.nim,
## src/docker/pull.nim): scan the image for an existing mark, collect around
## the real command, report the operation under its own name.
##
## Attestation works the same way it does for docker, which was NOT obvious:
## nothing in the signing path is docker-bound. signBySigStore lives in
## attestation_api.nim, it is triggered by the attestation plugin's run-time
## artifact callback (plugins/system.nim) which collectRunTimeArtifactInfo
## below invokes, and the upload goes out over plain registry HTTP
## (manifest.put -> registry.nim, which never shells out to docker). The only
## thing that was missing is chalk.repos: canVerifyBySigStore requires it to be
## non-empty, so with it unset the plugin skipped signing silently. collectRepos
## fills it from the image's registry references after the push lands.
##
## STILL NOT AT DOCKER PARITY on push:
##
##   * loginToRegistries()           src/docker/login.nim
##     Not called. Its config-driven HTTP login methods would work as-is; only
##     the password branch shells out to `docker login` (login.nim:79) and
##     would need a podman equivalent. Without it, private registries that
##     need auth will fail to attest.
##   * chalk.iterPushTags() fan-out  additional tags are not retagged/pushed
##   * completeBuildContextUploads() src/docker/context_upload.nim
##   * docker forces DOCKER_PLATFORM into the chalk keys at push so METADATA_*
##     stays unique per platform; we do not know the platform of a scanned
##     image.

import ".."/[
  attestation_api,
  collect,
  config,
  reporting,
  run_management,
  types,
  utils/exec,
  utils/json,
]
import "../docker"/[
  manifest,
]
import "./run"
import "./scan"
import "./notice"
import "./types" as podman_types

proc reportTransfer(chalk: ChalkObj, context: string) =
  chalk.addToAllChalks()
  chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack(context)
  collectChalkTimeArtifactInfo(chalk)
  collectRunTimeArtifactInfo(chalk)
  collectRunTimeHostInfo()
  try:
    doReporting("report")
  except:
    error("podman " & context & ": " & getCurrentExceptionMsg())

proc runPodmanPull*(exe: string, route: podman_types.PodmanRoute): int =
  ## Pull first, then scan what landed -- the image does not exist locally
  ## until the pull succeeds.
  setFullCommandName("pull")

  let pulled = runAttached(exe, route.originalArgs)
  if isCancellation(pulled):
    return cancellationExit(pulled)
  result = childStatus(pulled)
  setExitCode(result)
  if result != 0:
    return result

  var cancellation = none(podman_types.ChildResult)
  let chalkOpt = scanPodmanImage(exe, route.image, cancellation)
  if cancellation.isSome():
    return cancellationExit(cancellation.get())
  if chalkOpt.isNone():
    error("podman: " & route.image & " cannot be collected")
    emitPodmanSkip(PodmanSkip(
      operation: poPull,
      reason:    PodmanSkipReason(kind: psrImageScanUnavailable),
    ))
    return result

  let chalk = chalkOpt.get()
  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("podman: " & chalk.name &
           " is not chalked. reporting will be limited")
    initCollection()
    # Lets a pulled image be verified against its attestation, and matches what
    # docker records for the same operation.
    collectRepos(exe, route.image, chalk, cancellation)
    if cancellation.isSome():
      return cancellationExit(cancellation.get())
    chalk.reportTransfer("pull")

proc runPodmanPush*(exe: string, route: podman_types.PodmanRoute): int =
  ## Scan before pushing, so the report describes what was sent.
  setFullCommandName("push")
  loadAttestation(forceLoad = true, withPrivateKey = true)

  var cancellation = none(podman_types.ChildResult)
  let chalkOpt = scanPodmanImage(exe, route.image, cancellation)
  if cancellation.isSome():
    return cancellationExit(cancellation.get())

  if chalkOpt.isNone():
    error("podman: " & route.image & " is not found. pushing without chalk")
    emitPodmanSkip(PodmanSkip(
      operation: poPush,
      reason:    PodmanSkipReason(kind: psrImageScanUnavailable),
    ))
    let plain = runAttached(exe, route.originalArgs)
    if isCancellation(plain):
      return cancellationExit(plain)
    return setExitCode(childStatus(plain))

  let chalk = chalkOpt.get()
  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("podman: " & chalk.name &
           " is not chalked. reporting will be limited")
      # These plugins mint new identities (CHALK_ID, METADATA_ID). Pushing an
      # unmarked image should report what is there, not invent a mark for it.
      suspendChalkCollectionFor("attestation")
      suspendChalkCollectionFor("podman")

    initCollection()
    chalk.addToAllChalks()
    chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("push")
    collectChalkTimeArtifactInfo(chalk)

    let pushed = runAttached(exe, route.originalArgs)
    if isCancellation(pushed):
      return cancellationExit(pushed)
    result = childStatus(pushed)
    setExitCode(result)

    # Registry references only exist once the push has landed, and they are
    # what makes the image attestable -- so this must come after the push and
    # before run-time collection, which is where signing is triggered.
    if result == 0:
      collectRepos(exe, route.image, chalk, cancellation)
      if cancellation.isSome():
        return cancellationExit(cancellation.get())

    collectRunTimeArtifactInfo(chalk)
    collectRunTimeHostInfo()

    # Signing above only queues the attestation manifests; this uploads them.
    if result == 0:
      try:
        flushAttestationTags()
      except:
        error("podman push: could not push attestations: " &
              getCurrentExceptionMsg())

    try:
      doReporting("report")
    except:
      error("podman push: " & getCurrentExceptionMsg())
