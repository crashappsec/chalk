import std/[options, os, strutils, tempfiles]
import ../../src/docker/ids
import ../../src/podman/[binding, chalk_platform, cmdline, exec, host, image, inject,
                         notice, platform, types]
import ../../src/utils/json

proc header(target: ChalkPlatform): string =
  result = newString(20)
  result[0 .. 3] = "\x7fELF"
  result[4] = '\x02'
  result[5] = '\x01'
  result[6] = '\x01'
  result[18] = if target == cpLinuxAmd64: '\x3e' else: '\xb7'

let root = createTempDir("podman-platform-matrix-", "")
try:
  writeFile(root / "Containerfile", "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n")
  for target in ChalkPlatform:
    let binary = root / "chalk-" & $ord(target)
    writeFile(binary, header(target))
    doAssert readChalkPlatform(binary) == some(target)
    doAssert parseCommandPlatform($target) == some(target)
    let nativeArch = if target == cpLinuxAmd64: "amd64" else: "arm64"
    let alias = if target == cpLinuxAmd64: "x86_64" else: "aarch64"
    for arch in [nativeArch, alias]:
      let info = %*{"host": {"os": "linux", "arch": arch, "serviceIsRemote": false}}
      doAssert checkPodmanHost($info, target).kind == phrSupported
    let remote = %*{"host": {"os": "linux", "arch": nativeArch, "serviceIsRemote": true}}
    doAssert checkPodmanHost($remote, target).reason.kind == psrRemoteHost
    doAssert checkPodmanHost("{}", target).reason.kind == psrHostInfoInvalid
    for command in ChalkPlatform:
      let route = classifyPodmanArgs(@["build", "--platform", $command, root])
      doAssert route.kind == prInstrument
      let inputs = resolvePodmanInputs(route.spec, binary)
      if command == target:
        doAssert inputs.kind == pirResolved
        doAssert inputs.target == target
      else:
        doAssert inputs.kind == pirRefused
        doAssert inputs.reason.kind == psrCommandPlatformMismatch
    let implicit = classifyPodmanArgs(@["build", root])
    doAssert resolvePodmanInputs(implicit.spec, binary).target == target
    var spec = resolvePodmanInputs(implicit.spec, binary).spec
    let startup = planStartup(spec.startup, BaseExec(binding: BaseBinding(kind: bbScratch)))
    doAssert startup.kind == sprPlan
    spec.startupPlan = some(startup.plan)
    let workspace = preparePodmanBuild(spec, binary)
    doAssert workspace.isSome()
    doAssert readFile(workspace.get().assetContext / "chalk") == readFile(binary)
    removeDir(workspace.get().root)
    for imagePlatform in ChalkPlatform:
      let declared = parseDeclaredPlatform($imagePlatform)
      let arch = if imagePlatform == cpLinuxAmd64: "amd64" else: "arm64"
      let info = %*{"host": {"os": "linux", "arch": arch, "serviceIsRemote": false}}
      doAssert (checkPodmanHost($info, target).kind == phrSupported) == (imagePlatform == target)
      doAssert declaredPlatformSkip(declared, target).isNone() == (imagePlatform == target)
      let image = some(InspectedBaseImage(
        platform: declared,
        imageId: repeat('a', 64),
        binding: BaseBinding(kind: bbConfigId, configId: repeat('a', 64)),
      ))
      let decision = decideFinalBase("base", none(ChalkPlatform),
        DeclaredPlatform(kind: dpkAbsent), image, target)
      doAssert (decision.kind == fbdAccept) == (imagePlatform == target)
      if decision.kind == fbdSkip:
        doAssert decision.reason.kind == psrIncompatibleImagePlatform
      let proof = some(InspectedBaseImage(
        platform: parseDeclaredPlatform($target),
        imageId: repeat('a', 64),
        binding: BaseBinding(kind: bbRegistryDigest,
          reference: "example.test/base@sha256:" & repeat('b', 64),
          imageId: repeat('a', 64), proofPlatform: imagePlatform),
      ))
      let bindingDecision = decideFinalBase("base", some(target),
        DeclaredPlatform(kind: dpkAbsent), proof, target)
      doAssert (bindingDecision.kind == fbdAccept) == (imagePlatform == target)
      if bindingDecision.kind == fbdSkip:
        doAssert bindingDecision.reason.kind == psrImageBindingUnavailable
    doAssert decideFinalBase("scratch", none(ChalkPlatform),
      DeclaredPlatform(kind: dpkAbsent), none(InspectedBaseImage), target).kind == fbdAccept
    doAssert decideFinalBase("base", none(ChalkPlatform),
      DeclaredPlatform(kind: dpkUnresolved), none(InspectedBaseImage), target).reason.kind == psrUnresolvedImagePlatform
    for (field, value) in [(4, '\x01'), (5, '\x02'), (6, '\x00'), (18, '\xff'), (19, '\x01')]:
      var invalid = header(target)
      invalid[field] = value
      doAssert elfPlatform(invalid).isNone()
    doAssert elfPlatform(header(target)[0 .. 18]).isNone()
  doAssert readChalkPlatform(root / "missing").isNone()
  for value in ["", "linux/aarch64", "arm64", "LINUX/ARM64", "linux/arm64/v8", "linux/s390x"]:
    doAssert parseCommandPlatform(value).isNone()
finally:
  removeDir(root)
