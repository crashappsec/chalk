import std/os
import ../../src/podman/cmdline
import ../../src/podman/transfer
import ../../src/podman/types
import ../../src/confload
import ../../src/run_management
import ../../src/types as chalk_types

const sourceDir = currentSourcePath().parentDir().parentDir().parentDir() / "src"
{.passc: "-I" & sourceDir.}

proc runCmdInsert(path: seq[string])
    {.exportc: "runCmdInsert", cdecl.} =
  doAssert false, "runCmdInsert unexpectedly called with " & $path

proc runCmdExtract(path: seq[string])
    {.exportc: "runCmdExtract", cdecl.} =
  doAssert false, "runCmdExtract unexpectedly called with " & $path

proc runCmdDelete(path: seq[string])
    {.exportc: "runCmdDelete", cdecl.} =
  doAssert false, "runCmdDelete unexpectedly called with " & $path

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc exited(status: int): ChildResult =
  ChildResult(kind: ceExited, exitCode: status)

proc markedImage(): chalk_types.ChalkObj =
  newChalk(
    name = "img",
    imageId = "sha256:0123456789abcdef",
    extract = chalk_types.ChalkDict(),
  )

proc resetHooks() =
  podmanPushTestHooks = PodmanPushTestHooks()

proc route(): PodmanRoute =
  result = classifyPodmanArgs(@[
    "push", "--creds", "engine-user:engine-only-canary", "img",
  ])
  doAssert result.kind == prPush

proc expectPreparationFallback(step: PodmanPushPreparationStep) =
  resetHooks()
  var
    launches = 0
    seenArgs: seq[string]
  podmanPushTestHooks.loadAttestation = proc() =
    if step == pppsLoadAttestation:
      raise newException(IOError, "injected attestation failure")
  podmanPushTestHooks.scan = proc(
      exe, image: string,
      cancellation: var Option[ChildResult],
  ): Option[chalk_types.ChalkObj] =
    if step == pppsScan:
      raise newException(IOError, "injected scan temporary-file failure")
    some(markedImage())
  podmanPushTestHooks.initCollection = proc() =
    if step == pppsInitCollection:
      raise newException(IOError, "injected collection initialization failure")
  podmanPushTestHooks.collectChalkTime = proc(chalk: chalk_types.ChalkObj) =
    if step == pppsCollectChalkTime:
      raise newException(IOError, "injected chalk-time collection failure")
  podmanPushTestHooks.launch = proc(exe: string, args: seq[string]): ChildResult =
    inc launches
    seenArgs = args
    exited(23)

  assertEq(runPodmanPush("podman", route()), 23)
  assertEq(launches, 1)
  assertEq(seenArgs, route().originalArgs)

proc main() =
  loadAllConfigs()

  for step in [
    pppsLoadAttestation,
    pppsScan,
    pppsInitCollection,
    pppsCollectChalkTime,
  ]:
    expectPreparationFallback(step)

  resetHooks()
  var
    unavailableLaunches = 0
    unavailableFinishes = 0
  podmanPushTestHooks.loadAttestation = proc() = discard
  podmanPushTestHooks.scan = proc(
      exe, image: string,
      cancellation: var Option[ChildResult],
  ): Option[chalk_types.ChalkObj] =
    none(chalk_types.ChalkObj)
  podmanPushTestHooks.launch = proc(
      exe: string, args: seq[string],
  ): ChildResult =
    inc unavailableLaunches
    exited(29)
  podmanPushTestHooks.afterLaunch = proc(
      chalk: chalk_types.ChalkObj, status: int,
  ) =
    inc unavailableFinishes
  assertEq(runPodmanPush("podman", route()), 29)
  assertEq(unavailableLaunches, 1)
  assertEq(unavailableFinishes, 0)

  resetHooks()
  var cancellationLaunches = 0
  podmanPushTestHooks.loadAttestation = proc() = discard
  podmanPushTestHooks.scan = proc(
      exe, image: string,
      cancellation: var Option[ChildResult],
  ): Option[chalk_types.ChalkObj] =
    cancellation = some(ChildResult(
      kind: ceSignaled,
      signal: 2,
      forwardedSignal: 2,
    ))
    none(chalk_types.ChalkObj)
  podmanPushTestHooks.launch = proc(
      exe: string, args: seq[string],
  ): ChildResult =
    inc cancellationLaunches
    exited(0)
  assertEq(runPodmanPush("podman", route()), 130)
  assertEq(cancellationLaunches, 0)

  for nativeStatus in [0, 19]:
    resetHooks()
    var launches = 0
    podmanPushTestHooks.loadAttestation = proc() = discard
    podmanPushTestHooks.scan = proc(
        exe, image: string,
        cancellation: var Option[ChildResult],
    ): Option[chalk_types.ChalkObj] =
      some(markedImage())
    podmanPushTestHooks.initCollection = proc() = discard
    podmanPushTestHooks.collectChalkTime = proc(
        chalk: chalk_types.ChalkObj,
    ) = discard
    podmanPushTestHooks.launch = proc(
        exe: string, args: seq[string],
    ): ChildResult =
      inc launches
      exited(nativeStatus)
    podmanPushTestHooks.afterLaunch = proc(
        chalk: chalk_types.ChalkObj, status: int,
    ) =
      raise newException(IOError, "injected post-launch reporting failure")
    assertEq(runPodmanPush("podman", route()), nativeStatus)
    assertEq(launches, 1)

  resetHooks()
  var unknownLaunches = 0
  podmanPushTestHooks.loadAttestation = proc() = discard
  podmanPushTestHooks.scan = proc(
      exe, image: string,
      cancellation: var Option[ChildResult],
  ): Option[chalk_types.ChalkObj] =
    some(markedImage())
  podmanPushTestHooks.initCollection = proc() = discard
  podmanPushTestHooks.collectChalkTime = proc(
      chalk: chalk_types.ChalkObj,
  ) = discard
  podmanPushTestHooks.launch = proc(
      exe: string, args: seq[string],
  ): ChildResult =
    inc unknownLaunches
    raise newException(IOError, "injected launch adapter failure")
  assertEq(runPodmanPush("podman", route()), 1)
  assertEq(unknownLaunches, 1)

  resetHooks()

main()
