##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
]
import ".."/[
  attestation_api,
  chalkjson,
  collect,
  config,
  plugin_api,
  reportcache,
  reporting,
  run_management,
  types,
  utils/files,
  utils/exec,
  utils/json,
]
import "../docker"/ids
import "./cmdline"
import "./exec" as podman_exec
import "./host"
import "./image"
import "./inject"
import "./notice"
import "./platform"
import "./report"
import "./run"
import "./transfer"
import "./types" as podman_types

proc redactCollectedArgs(spec: podman_types.PodmanBuildSpec,
                         chalk: ChalkObj = nil) =
  redactPodmanReportFields(hostInfo, spec.confidentialArgs)
  if chalk != nil:
    redactPodmanReportFields(chalk.collectedData, spec.confidentialArgs)

proc installPodmanReportArgs(spec: podman_types.PodmanBuildSpec) =
  setArgs(spec.reportArgs)

proc doPodmanReporting(spec: podman_types.PodmanBuildSpec, topic: string,
                       chalk: ChalkObj = nil) =
  collectRunTimeHostInfo()
  redactCollectedArgs(spec, chalk)
  suspendHostCollection()
  try:
    if spec.quietOutput:
      doReportingWithStdoutRedirected(topic)
    else:
      doReporting(topic)
  finally:
    restoreHostCollection()

proc failOpenOriginal(exe: string, spec: podman_types.PodmanBuildSpec,
                      step: PodmanAttemptStep,
                      attemptStatus = none(int)): int =
  emitPodmanRetryStart(step, attemptStatus)
  let retried = runAttached(exe, spec.originalArgs)
  if isCancellation(retried):
    return cancellationExit(retried)
  let status = childStatus(retried)
  if status == 0:
    emitPodmanRetryResult(NativeRetryResult(kind: nrSucceeded))
  else:
    emitPodmanRetryResult(NativeRetryResult(kind: nrExited, status: status))
  setExitCode(status)
  try:
    doPodmanReporting(spec, "fail")
  except:
    discard
  return status

proc writeMark(spec: podman_types.PodmanBuildSpec,
               ws: podman_types.PodmanWorkspace): Option[ChalkObj] =
  let chalk = newChalk(
    name         = primaryTag(spec),
    resourceType = {ResourceImage},
    codec        = getPluginByName("podman"),
    chalkId      = dockerGenerateChalkId(),
  )
  chalk.collectedData.setIfNeeded("DOCKER_FILE", spec.containerfileText)
  chalk.collectedData.setIfNeeded("DOCKER_FILE_CHALKED", ws.derivedText)
  chalk.collectedData.setIfNeeded("DOCKERFILE_PATH", spec.resolvedContainerfile)
  chalk.collectedData.setIfNeeded("DOCKER_CONTEXT", spec.contextArg)
  chalk.collectedData.setIfNeeded("DOCKER_PLATFORM", spec.platform)
  chalk.collectedData.setIfNeeded("DOCKER_PLATFORMS", @[spec.platform])
  if len(spec.tags) > 0:
    chalk.collectedData.setIfNeeded("DOCKER_TAGS", spec.tags)
  if spec.target != "":
    chalk.collectedData.setIfSubscribed("DOCKER_TARGET", spec.startup.stageAlias)
  redactCollectedArgs(spec)
  collectChalkTimeArtifactInfo(chalk)
  redactCollectedArgs(spec, chalk)
  let mark = chalk.getChalkMarkAsStr()
  writeFile(ws.assetContext / "chalk.json", mark)
  discard chmodFilePermissions(ws.assetContext / "chalk.json", "0444")
  chalk.marked = true
  return some(chalk)

proc finalizeImage(exe: string, spec: podman_types.PodmanBuildSpec,
                   ws: podman_types.PodmanWorkspace, chalk: ChalkObj): int =
  var imageId = ""
  if fileExists(ws.iidFile):
    imageId = extractDockerHash(tryToLoadFile(ws.iidFile).strip())
  if imageId == "" and primaryTag(spec) != "":
    let inspected = runCaptured(exe, @["image", "inspect", primaryTag(spec)])
    if isCancellation(inspected.child):
      return cancellationExit(inspected.child)
    if inspected.child.kind == podman_types.ceExited and
        inspected.child.exitCode == 0:
      try:
        imageId = extractDockerHash(parseJson(inspected.stdout)[0]{"Id"}.getStr())
      except:
        discard
  if imageId != "":
    chalk.imageId = imageId
    chalk.cachedEndingHash = imageId
    if chalk.name == "":
      # An untagged build has no other handle for the artifact.
      chalk.name = imageId
  chalk.addToAllChalks()
  chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("build")
  collectRunTimeArtifactInfo(chalk)
  try:
    doPodmanReporting(spec, "report", chalk)
  except:
    error("podman post-command: " & getCurrentExceptionMsg())
  return 0

proc beginAcceptedCollection(spec: podman_types.PodmanBuildSpec) =
  setFullCommandName("build")
  forceReportKeys(["_OP_ARTIFACT_TYPE", "PODMAN_IMAGE_ID"])
  setContextDirectories(@[spec.resolvedContext])
  loadAttestation(forceLoad = true, withPrivateKey = true)
  initCollection()

proc runPodmanCommand*(exe: string, args: seq[string], chalkPath: string): int =
  let route = classifyPodmanArgs(args)
  if exe == "":
    var operation = none(PodmanOperation)
    case route.kind
    of prPassThrough:
      if route.skip.isSome():
        operation = some(route.skip.get().operation)
    of prInstrument:
      operation = some(poBuild)
    of prPush:
      operation = some(poPush)
    of prPull:
      operation = some(poPull)
    if operation.isSome():
      emitPodmanSkip(PodmanSkip(
        operation: operation.get(),
        reason: PodmanSkipReason(kind: psrNativeExecutableUnavailable),
      ))
    return 127

  if route.kind == prInstrument:
    installPodmanReportArgs(route.spec)

  if route.kind == prPassThrough:
    if route.skip.isSome():
      emitPodmanSkip(route.skip.get())
    execReplacingSelf(exe, route.originalArgs)

  case route.kind
  of prPull:
    return runPodmanPull(exe, route)
  of prPush:
    return runPodmanPush(exe, route)
  else:
    discard

  let resolved = resolvePodmanInputs(route.spec, chalkPath)
  if resolved.kind == pirRefused:
    emitPodmanSkip(PodmanSkip(operation: poBuild, reason: resolved.reason))
    execReplacingSelf(exe, route.spec.originalArgs)
  var spec = resolved.spec
  disableReportCacheForRun()

  let info = runCaptured(exe, @["info", "--format", "json"])
  if isCancellation(info.child):
    return cancellationExit(info.child)
  if info.child.kind != podman_types.ceExited or info.child.exitCode != 0:
    try:
      beginAcceptedCollection(spec)
    except:
      discard
    let status =
      if info.child.kind == podman_types.ceExited: some(info.child.exitCode)
      else: none(int)
    return failOpenOriginal(exe, spec, pasHostInspection, status)
  let hostPlatform = checkPodmanHost(info.stdout)
  if hostPlatform.kind == phrRefused:
    emitPodmanSkip(PodmanSkip(operation: poBuild,
                             reason: hostPlatform.reason))
    execReplacingSelf(exe, spec.originalArgs)
  spec.guardNoNetwork = guardCanSkipNetwork(info.stdout)

  let
    fromPlatform = spec.startup.fromPlatform
    rootImage = spec.startup.rootImage
    rootIsScratch = rootImage == "scratch"
    declaredSkip = declaredPlatformSkip(fromPlatform)
  if declaredSkip.isSome():
    emitPodmanSkip(PodmanSkip(operation: poBuild,
                             reason: declaredSkip.get()))
    execReplacingSelf(exe, spec.originalArgs)

  var
    cancellation = none(podman_types.ChildResult)
    inspected = none(InspectedBaseImage)
  # Platform compatibility is independent of startup inheritance: an explicit
  # ENTRYPOINT must not skip this check.
  if not rootIsScratch:
    inspected = fetchBaseImage(exe, rootImage, cancellation, spec.pullPolicy,
                               spec.platform, spec.startup.rootFromPlatform,
                               spec.startup.effectiveStageCount)
    if cancellation.isSome():
      return cancellationExit(cancellation.get())
  let base = decideFinalBase(rootImage, spec.platform, fromPlatform, inspected)
  if base.kind == fbdSkip:
    emitPodmanSkip(PodmanSkip(operation: poBuild, reason: base.reason))
    execReplacingSelf(exe, spec.originalArgs)

  if spec.platform == "":
    # --platform was omitted, so podman builds for the host platform, which the
    # check above has just confirmed is one we can instrument.
    spec.platform = hostPlatform.platform

  let startup = podman_exec.planStartup(spec.startup, base.root)
  if startup.kind == podman_exec.sprRefuse:
    emitPodmanSkip(PodmanSkip(
      operation: poBuild,
      reason:    PodmanSkipReason(kind: psrNoStartup),
    ))
    execReplacingSelf(exe, spec.originalArgs)
  spec.startupPlan = some(startup.plan)

  try:
    beginAcceptedCollection(spec)
  except:
    return failOpenOriginal(exe, spec, pasCollectionInitialization)

  let wsOpt = preparePodmanBuild(spec)
  if wsOpt.isNone():
    return failOpenOriginal(exe, spec, pasWorkspacePreparation)
  let ws = wsOpt.get()

  var chalkOpt: Option[ChalkObj]
  try:
    chalkOpt = writeMark(spec, ws)
  except:
    return failOpenOriginal(exe, spec, pasMarkCreation)
  if chalkOpt.isNone():
    return failOpenOriginal(exe, spec, pasMarkCreation)
  let chalk = chalkOpt.get()

  let injected = runAttached(exe, makeInjectedArgs(spec, ws))
  if isCancellation(injected):
    return cancellationExit(injected)
  if injected.kind == podman_types.ceSpawnFailed:
    return failOpenOriginal(exe, spec, pasInstrumentedBuildStart)
  if injected.kind != podman_types.ceExited:
    return childStatus(injected)
  if injected.exitCode != 0:
    return failOpenOriginal(exe, spec, pasInstrumentedBuildRun,
                            some(injected.exitCode))

  try:
    let status = finalizeImage(exe, spec, ws, chalk)
    if status != 0:
      return status
  except:
    error("podman post-command: " & getCurrentExceptionMsg())
  return 0

proc runPodman*(args: seq[string]): int =
  return runPodmanCommand(resolvePodmanExe(), args, getMyAppPath())
