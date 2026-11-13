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
## non-empty, so with it unset the plugin skipped signing silently.
## collectPublishedRepo fills it from the destination after the push lands.
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
##     stays unique per platform; Podman collects the scanned image platform
##     but does not force that key at push.

import ".."/[
  attestation_api,
  collect,
  config,
  run_management,
  types,
  utils/exec,
]
import "../docker"/[
  manifest,
  registry,
]
import "./run"
import "./report"
import "./scan"
import "./sbom"
import "./notice"
import "./types" as podman_types

type PodmanPushPreparationStep* = enum
  pppsLoadAttestation,
  pppsScan,
  pppsInitCollection,
  pppsCollectChalkTime

when defined(podmanTransferTestHooks):
  type PodmanPushTestHooks* = object
    loadAttestation*: proc() {.closure.}
    scan*: proc(
      exe, image: string,
      cancellation: var Option[podman_types.ChildResult],
    ): Option[ChalkObj] {.closure.}
    initCollection*: proc() {.closure.}
    collectChalkTime*: proc(chalk: ChalkObj) {.closure.}
    launch*: proc(
      exe: string,
      args: seq[string],
    ): podman_types.ChildResult {.closure.}
    afterLaunch*: proc(chalk: ChalkObj, status: int) {.closure.}

  var podmanPushTestHooks*: PodmanPushTestHooks

proc preparePushAttestation() =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.loadAttestation != nil:
      podmanPushTestHooks.loadAttestation()
      return
  loadAttestation(forceLoad = true, withPrivateKey = true)

proc scanPushImage(
    exe, image: string,
    cancellation: var Option[podman_types.ChildResult],
): Option[ChalkObj] =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.scan != nil:
      return podmanPushTestHooks.scan(exe, image, cancellation)
  return scanPodmanImage(exe, image, cancellation)

proc initializePushCollection() =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.initCollection != nil:
      podmanPushTestHooks.initCollection()
      return
  initCollection()

proc collectPushChalkTime(chalk: ChalkObj) =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.collectChalkTime != nil:
      podmanPushTestHooks.collectChalkTime(chalk)
      return
  collectChalkTimeArtifactInfo(chalk)

proc launchPush(exe: string, args: seq[string]): podman_types.ChildResult =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.launch != nil:
      return podmanPushTestHooks.launch(exe, args)
  return runAttached(exe, args)

proc reportTransfer(chalk: ChalkObj, context: string,
                    route: podman_types.PodmanRoute) =
  chalk.addToAllChalks()
  chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack(context)
  collectChalkTimeArtifactInfo(chalk)
  collectRunTimeArtifactInfo(chalk)
  try:
    doPodmanReporting(route.reportArgs, route.confidentialArgs, "report")
  except CatchableError:
    error("podman " & context & ": reporting failed")

proc runPodmanPull*(exe: string, route: podman_types.PodmanRoute): int =
  ## Pull first, then scan what landed -- the image does not exist locally
  ## until the pull succeeds.
  setFullCommandName("pull")
  setArgs(route.reportArgs)

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
    chalk.reportTransfer("pull", route)

proc runOriginalPushOnce(
    exe: string,
    route: podman_types.PodmanRoute,
): tuple[status: int, completed: bool] =
  var pushed: podman_types.ChildResult
  try:
    pushed = launchPush(exe, route.originalArgs)
  except CatchableError:
    # The launch adapter may have started Podman before raising. The native
    # outcome is unknown, so never replay the command.
    try:
      error("podman push: native command outcome is unknown")
    except CatchableError:
      discard
    setExitCode(1)
    return (1, false)
  if isCancellation(pushed):
    return (cancellationExit(pushed), false)
  result = (childStatus(pushed), true)
  setExitCode(result.status)

proc finishPush(
    chalk: ChalkObj,
    status: int,
    route: podman_types.PodmanRoute,
) =
  when defined(podmanTransferTestHooks):
    if podmanPushTestHooks.afterLaunch != nil:
      podmanPushTestHooks.afterLaunch(chalk, status)
      return

  withRegistryAccess(newAuthFileRegistryAccess(route.authfile)):
    # Registry references only exist once the push has landed, and they are
    # what makes the image attestable -- so this must come after the push and
    # before run-time collection, which is where signing is triggered.
    if status == 0:
      collectPublishedRepo(route.destination.get(route.image), chalk)
      maybeCollectHandoffSbom(
        attrGetOpt[string]("sbom_handoff").get(""),
        chalk,
        chalk.imageId,
      )

    collectRunTimeArtifactInfo(chalk)

    # Signing above only queues the attestation manifests; this uploads them.
    if status == 0:
      try:
        flushAttestationTags()
      except CatchableError:
        error("podman push: could not push attestations")

    doPodmanReporting(route.reportArgs, route.confidentialArgs, "report")

proc runPodmanPush*(exe: string, route: podman_types.PodmanRoute): int =
  ## Scan before pushing, so the report describes what was sent.
  setFullCommandName("push")
  setArgs(route.reportArgs)

  var
    cancellation = none(podman_types.ChildResult)
    chalk: ChalkObj
    collectAfterPush = false
  try:
    preparePushAttestation()
    let chalkOpt = scanPushImage(exe, route.image, cancellation)
    if cancellation.isSome():
      return cancellationExit(cancellation.get())

    if chalkOpt.isNone():
      error("podman: image cannot be collected; pushing without collection")
      emitPodmanSkip(PodmanSkip(
        operation: poPush,
        reason:    PodmanSkipReason(kind: psrImageScanUnavailable),
      ))
    else:
      chalk = chalkOpt.get()
      chalk.withErrorContext():
        # An externally supplied or modified mark may contain repository
        # fields from another publication. This push must report only what it
        # publishes.
        for key in ["_REPO_DIGESTS", "_REPO_LIST_DIGESTS", "_REPO_TAGS"]:
          chalk.collectedData.del(key)

        if not chalk.isChalked():
          warn("podman: " & chalk.name &
               " is not chalked. reporting will be limited")
          # These plugins mint new identities (CHALK_ID, METADATA_ID). Pushing
          # an unmarked image should report what is there, not invent a mark.
          suspendChalkCollectionFor("attestation")
          suspendChalkCollectionFor("podman")

        initializePushCollection()
        chalk.addToAllChalks()
        chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("push")
        collectPushChalkTime(chalk)
      collectAfterPush = true
  except CatchableError:
    try:
      redactPodmanRetainedState(route.confidentialArgs)
    except CatchableError:
      discard
    try:
      error("podman push: preparation failed; pushing without collection")
    except CatchableError:
      discard

  # This is the exact launch boundary. Nothing below may invoke Podman again.
  let pushed = runOriginalPushOnce(exe, route)
  result = pushed.status
  if not pushed.completed:
    return result
  if not collectAfterPush:
    return result
  try:
    chalk.withErrorContext():
      finishPush(chalk, result, route)
  except CatchableError:
    try:
      redactPodmanRetainedState(route.confidentialArgs)
    except CatchableError:
      discard
    try:
      error("podman push: post-command collection failed")
    except CatchableError:
      discard
