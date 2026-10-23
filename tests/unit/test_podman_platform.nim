import std/[options, strutils]
import ../../src/docker/ids
import ../../src/podman/binding
import ../../src/podman/image
import ../../src/podman/notice
import ../../src/podman/platform
import ../../src/utils/json

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc expectPlatform(value, os, arch: string) =
  let parsed = parseDeclaredPlatform(value)
  assertEq(parsed.kind, dpkKnown)
  assertEq(parsed.platform.os, os)
  assertEq(parsed.platform.architecture, arch)

proc expectPlatformUnresolved(value: string) =
  assertEq(parseDeclaredPlatform(value).kind, dpkUnresolved)

proc expectReason(reason: Option[PodmanSkipReason],
                  kind: PodmanSkipReasonKind) =
  doAssert reason.isSome()
  assertEq(reason.get().kind, kind)

proc expectDecisionReason(decision: FinalBaseDecision,
                          kind: PodmanSkipReasonKind) =
  assertEq(decision.kind, fbdSkip)
  assertEq(decision.reason.kind, kind)

expectPlatform("linux/amd64", "linux", "amd64")
expectPlatform("LINUX/AMD64", "linux", "amd64")
expectPlatform("linux/amd64/v3", "linux", "amd64")
expectPlatform("linux/x86_64", "linux", "amd64")
expectPlatform("linux/arm64", "linux", "arm64")
expectPlatform("linux/aarch64", "linux", "arm64")
expectPlatform("amd64", "linux", "amd64")
expectPlatform("arm64", "linux", "arm64")
expectPlatformUnresolved("")
expectPlatformUnresolved("linux")
expectPlatformUnresolved("linux/")
expectPlatformUnresolved("a/b/c/d")

let
  imageId = repeat('a', 64)
  amd64 = parseDeclaredPlatform("linux/amd64")
  x86 = parseDeclaredPlatform("linux/x86_64")
  arm64 = parseDeclaredPlatform("linux/arm64")
  windows = parseDeclaredPlatform("windows/amd64")
  absent = DeclaredPlatform(kind: dpkAbsent)
  requestedAmd64 = DeclaredPlatform(
    kind: dpkRequested, platform: amd64.platform)
  requestedArm64 = DeclaredPlatform(
    kind: dpkRequested, platform: arm64.platform)
  unresolved = DeclaredPlatform(kind: dpkUnresolved)
doAssert declaredPlatformSkip(absent).isNone()
doAssert declaredPlatformSkip(amd64).isNone()
doAssert declaredPlatformSkip(x86).isNone()
expectReason(declaredPlatformSkip(arm64), psrIncompatibleImagePlatform)
expectReason(declaredPlatformSkip(windows), psrIncompatibleImagePlatform)
doAssert declaredPlatformSkip(requestedAmd64).isNone()
expectReason(declaredPlatformSkip(requestedArm64),
             psrUnresolvedImagePlatform)
expectReason(declaredPlatformSkip(unresolved), psrUnresolvedImagePlatform)

let
  inspectedAmd64 = some(InspectedBaseImage(
    entrypoint: %*["/bin/sh"],
    cmd:        %*["-c"],
    platform:   amd64,
    imageId:    imageId,
    binding:    BaseBinding(kind: bbConfigId, configId: imageId),
  ))
  inspectedX86 = some(InspectedBaseImage(
    platform: x86,
    imageId: imageId,
    binding: BaseBinding(kind: bbConfigId, configId: imageId),
  ))
  inspectedArm = some(InspectedBaseImage(
    platform: arm64,
    imageId: imageId,
    binding: BaseBinding(kind: bbConfigId, configId: imageId),
  ))
  inspectedUnknown = some(InspectedBaseImage(
    platform: DeclaredPlatform(kind: dpkUnresolved),
    imageId: imageId,
    binding: BaseBinding(kind: bbConfigId, configId: imageId),
  ))

let accepted = decideFinalBase("example/base:latest", "", absent,
                               inspectedAmd64)
assertEq(accepted.kind, fbdAccept)
assertEq(accepted.root.entrypoint, %*["/bin/sh"])
assertEq(accepted.root.cmd, %*["-c"])
assertEq(accepted.root.binding.kind, bbConfigId)
assertEq(decideFinalBase("example/base:latest", "", amd64,
                         inspectedX86).kind, fbdAccept)
assertEq(decideFinalBase("example/base:latest", "", requestedAmd64,
                         inspectedAmd64).kind, fbdAccept)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", absent, inspectedArm),
  psrIncompatibleImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", requestedAmd64,
                  inspectedArm),
  psrIncompatibleImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", requestedArm64,
                  inspectedAmd64),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", amd64, inspectedArm),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "linux/amd64", absent,
                  inspectedArm),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase(
    "example/base@sha256:0123456789abcdef", "linux/amd64", absent,
    inspectedArm),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase(
    "example/base@sha256:0123456789abcdef", "", amd64,
    inspectedArm),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase(
    "example/base@sha256:0123456789abcdef", "", absent,
    inspectedArm),
  psrIncompatibleImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", absent, inspectedUnknown),
  psrUnresolvedImagePlatform,
)
expectDecisionReason(
  decideFinalBase("example/base:latest", "", absent,
                  none(InspectedBaseImage)),
  psrImageBindingUnavailable,
)
expectDecisionReason(
  decideFinalBase("scratch", "", arm64, none(InspectedBaseImage)),
  psrIncompatibleImagePlatform,
)
let scratch = decideFinalBase("scratch", "", absent,
                              none(InspectedBaseImage))
assertEq(scratch.kind, fbdAccept)
doAssert scratch.root.entrypoint == nil
doAssert scratch.root.cmd == nil
assertEq(scratch.root.binding.kind, bbScratch)

let inspectAmd64 = parseInspectedBaseImage(
  "[{\"Id\":\"" & imageId &
  "\",\"Os\":\"linux\",\"Architecture\":\"amd64\",\"Config\":{" &
  "\"Entrypoint\":[\"/bin/sh\"],\"Cmd\":[\"-c\"]}}]"
)
doAssert inspectAmd64.isSome()
assertEq(inspectAmd64.get().platform.kind, dpkKnown)
assertEq(inspectAmd64.get().platform.platform.os, "linux")
assertEq(inspectAmd64.get().platform.platform.architecture, "amd64")
assertEq(inspectAmd64.get().entrypoint, %*["/bin/sh"])
assertEq(inspectAmd64.get().cmd, %*["-c"])
let inspectArm = parseInspectedBaseImage(
  "[{\"Id\":\"" & imageId &
  "\",\"Os\":\"linux\",\"Architecture\":\"arm64\",\"Config\":{" &
  "\"Entrypoint\":null,\"Cmd\":[]}}]"
)
doAssert inspectArm.isSome()
assertEq(inspectArm.get().platform.kind, dpkKnown)
assertEq(inspectArm.get().platform.platform.architecture, "arm64")
doAssert inspectArm.get().entrypoint == nil
doAssert inspectArm.get().cmd == nil
doAssert parseInspectedBaseImage("not json").isNone()
doAssert parseInspectedBaseImage("[]").isNone()
let inspectNoConfig = parseInspectedBaseImage(
  "[{\"Id\":\"" & imageId &
  "\",\"Os\":\"linux\",\"Architecture\":\"arm64\"}]"
)
doAssert inspectNoConfig.isSome()
assertEq(inspectNoConfig.get().platform.kind, dpkKnown)
assertEq(inspectNoConfig.get().platform.platform.architecture, "arm64")

let inspectUnknown = parseInspectedBaseImage(
  "[{\"Id\":\"" & imageId & "\",\"Os\":\"linux\",\"Config\":{}}]"
)
doAssert inspectUnknown.isSome()
assertEq(inspectUnknown.get().platform.kind, dpkUnresolved)
