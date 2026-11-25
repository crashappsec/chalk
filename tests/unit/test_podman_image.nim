import ../../src/podman/chalk_platform
import std/[
  json,
  options,
  os,
  posix,
  strutils,
]
import ../../src/docker/ids
import ../../src/podman/binding
import ../../src/podman/image
import ../../src/podman/types

const
  sourceDir = currentSourcePath().parentDir().parentDir().parentDir() / "src"
  BaseRef = "registry.example/customer/base:latest"
  ImageAId = "a".repeat(64)
  ImageBId = "b".repeat(64)
  ArmImageId = "c".repeat(64)
  DigestA = "sha256:" & "1".repeat(64)
  ChildDigest = "sha256:" & "2".repeat(64)

{.passc: "-I" & sourceDir.}

proc recordedCalls(path: string): seq[seq[string]] =
  for line in readFile(path).splitLines():
    if line == "":
      continue
    var args: seq[string]
    for value in parseJson(line):
      args.add(value.getStr())
    result.add(args)

proc runFakePodman() =
  let argv = commandLineParams()
  var encoded = newJArray()
  for arg in argv:
    encoded.add(%arg)
  let logStream = open(getEnv("PODMAN_IMAGE_TEST_LOG"), fmAppend)
  logStream.writeLine($encoded)
  logStream.close()

  if argv.len >= 3 and argv[0 .. 1] == @["image", "inspect"]:
    if argv[2] == getEnv("PODMAN_IMAGE_TEST_ORIGINAL"):
      if getEnv("PODMAN_IMAGE_TEST_ORIGINAL_CANCEL") == "1":
        discard kill(getpid(), SIGTERM)
        quit(99)
      let originalExit = getEnv("PODMAN_IMAGE_TEST_ORIGINAL_EXIT")
      if originalExit != "":
        stdout.write(getEnv("PODMAN_IMAGE_TEST_ORIGINAL_STDOUT"))
        stderr.write(getEnv("PODMAN_IMAGE_TEST_ORIGINAL_STDERR"))
        quit(parseInt(originalExit))
    if getEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING") == "1" and
        argv[2] == getEnv("PODMAN_IMAGE_TEST_ORIGINAL"):
      stdout.write("[]\n")
      stderr.write("Error: " & argv[2] & ": image not known\n")
      quit(125)
    if getEnv("PODMAN_IMAGE_TEST_INSPECT_CANCEL") == "1":
      discard kill(getpid(), SIGTERM)
      quit(99)
    if getEnv("PODMAN_IMAGE_TEST_INSPECT_FAIL") == "1":
      quit(125)
    stdout.write(getEnv("PODMAN_IMAGE_TEST_INSPECT"))
    quit(0)

  if argv.len >= 3 and argv[0 .. 1] == @["pull", "--quiet"]:
    let proof = "@sha256:" in argv[^1]
    if proof:
      if getEnv("PODMAN_IMAGE_TEST_PROOF_CANCEL") == "1":
        discard kill(getpid(), SIGTERM)
        quit(99)
      if getEnv("PODMAN_IMAGE_TEST_PROOF_FAIL") == "1":
        quit(125)
      stdout.write(getEnv("PODMAN_IMAGE_TEST_PROOF_STDOUT"))
    else:
      if getEnv("PODMAN_IMAGE_TEST_PULL_CANCEL") == "1":
        discard kill(getpid(), SIGTERM)
        quit(99)
      if getEnv("PODMAN_IMAGE_TEST_PULL_FAIL") == "1":
        quit(125)
      stdout.write(getEnv("PODMAN_IMAGE_TEST_PULL_STDOUT"))
    quit(0)

  quit(99)

if getEnv("PODMAN_IMAGE_TEST_CHILD") == "1":
  runFakePodman()

let
  root = getTempDir() / ("chalk-podman-image-" & $getCurrentProcessId())
  fake = getAppFilename()
  log = root / "calls.jsonl"

createDir(root)
putEnv("PODMAN_IMAGE_TEST_LOG", log)
putEnv("PODMAN_IMAGE_TEST_CHILD", "1")

proc inspection(id = ImageAId,
                architecture = "amd64",
                digest = DigestA,
                repoDigests = @[BaseRef.split(':')[0] & "@" & DigestA]): string =
  var repositories = newJArray()
  for item in repoDigests:
    repositories.add(%item)
  let value = %* [{
    "Id": id,
    "Digest": digest,
    "RepoDigests": repositories,
    "Os": "linux",
    "Architecture": architecture,
    "Config": {
      "Entrypoint": ["/bin/sh"],
      "Cmd": ["-c"],
    },
  }]
  return $value

const CaseVariables = [
  "PODMAN_IMAGE_TEST_ORIGINAL_MISSING",
  "PODMAN_IMAGE_TEST_ORIGINAL_CANCEL",
  "PODMAN_IMAGE_TEST_ORIGINAL_EXIT",
  "PODMAN_IMAGE_TEST_ORIGINAL_STDOUT",
  "PODMAN_IMAGE_TEST_ORIGINAL_STDERR",
  "PODMAN_IMAGE_TEST_INSPECT_CANCEL",
  "PODMAN_IMAGE_TEST_INSPECT_FAIL",
  "PODMAN_IMAGE_TEST_PULL_CANCEL",
  "PODMAN_IMAGE_TEST_PULL_FAIL",
  "PODMAN_IMAGE_TEST_PROOF_CANCEL",
  "PODMAN_IMAGE_TEST_PROOF_FAIL",
]

proc resetCase(original = BaseRef) =
  writeFile(log, "")
  for name in CaseVariables:
    delEnv(name)
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL", original)
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection())
  putEnv("PODMAN_IMAGE_TEST_PULL_STDOUT", ImageAId & "\n")
  putEnv("PODMAN_IMAGE_TEST_PROOF_STDOUT", ImageAId & "\n")

proc setOriginalResult(exitCode: int, output, error: string) =
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_EXIT", $exitCode)
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_STDOUT", output)
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_STDERR", error)

type FetchResult = tuple[
  image: Option[InspectedBaseImage],
  cancellation: Option[ChildResult],
]

proc fetch(image = BaseRef,
           policy = bppMissing,
           commandPlatform = "",
           rootPlatform = DeclaredPlatform(kind: dpkAbsent),
           effectiveStageCount = 1,
           target = cpLinuxAmd64): FetchResult =
  var cancellation = none(ChildResult)
  result.image = fetchBaseImage(
    fake,
    image,
    cancellation,
    target,
    policy,
    parseCommandPlatform(commandPlatform),
    rootPlatform,
    effectiveStageCount,
   )
  result.cancellation = cancellation

proc expectCalls(expected: seq[seq[string]]) =
  doAssert recordedCalls(log) == expected,
    "expected " & $expected & ", got " & $recordedCalls(log)

proc expectConfigBinding(fetched: FetchResult, id = ImageAId) =
  doAssert fetched.cancellation.isNone()
  doAssert fetched.image.isSome()
  doAssert fetched.image.get().imageId == id
  doAssert fetched.image.get().binding.kind == bbConfigId
  doAssert fetched.image.get().binding.configId == id

resetCase()
let missingLocal = fetch()
expectConfigBinding(missingLocal)
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
let missingAbsent = fetch()
expectConfigBinding(missingAbsent)
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

for request in [
  (command: "linux/amd64",
   root: DeclaredPlatform(kind: dpkAbsent), stages: 1),
  (command: "",
   root: parseDeclaredPlatform("linux/amd64"), stages: 1),
  (command: "",
   root: DeclaredPlatform(kind: dpkAbsent), stages: 2),
]:
  resetCase()
  let promoted = fetch(
    commandPlatform = request.command,
    rootPlatform = request.root,
    effectiveStageCount = request.stages,
  )
  expectConfigBinding(promoted)
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])

  resetCase()
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
  let promotedAbsent = fetch(
    commandPlatform = request.command,
    rootPlatform = request.root,
    effectiveStageCount = request.stages,
  )
  expectConfigBinding(promotedAbsent)
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
    @["pull", "--quiet", "--platform", "linux/amd64", BaseRef],
    @["image", "inspect", ImageAId, "--format", "json"],
  ])

resetCase()
setOriginalResult(
  125,
  " \n[]\n",
  "Warning: using local image storage\n\nError: " & BaseRef &
    ": image not known\n\n",
)
let missingAfterWarning = fetch()
expectConfigBinding(missingAfterWarning)
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

for taggedDigest in [
  (reference: "alpine:latest@" & DigestA,
   diagnostic: "alpine@" & DigestA),
  (reference: "registry.example:5000/team/base:latest@" & DigestA,
   diagnostic: "registry.example:5000/team/base@" & DigestA),
]:
  let reference = taggedDigest.reference
  resetCase(reference)
  setOriginalResult(
    125,
    "[]\n",
    "Error: " & taggedDigest.diagnostic & ": image not known\n",
  )
  let missingTaggedDigest = fetch(image = reference)
  expectConfigBinding(missingTaggedDigest)
  expectCalls(@[
    @["image", "inspect", reference, "--format", "json"],
    @["pull", "--quiet", reference],
    @["image", "inspect", ImageAId, "--format", "json"],
  ])

let exactMissingDiagnostic = "Error: " & BaseRef & ": image not known\n"
for rejected in [
  (exitCode: 0, output: "[]\n", error: exactMissingDiagnostic),
  (exitCode: 44, output: "[]\n", error: exactMissingDiagnostic),
  (exitCode: 125, output: "[{}]\n", error: exactMissingDiagnostic),
  (exitCode: 125, output: "not-json\n", error: exactMissingDiagnostic),
  (exitCode: 125, output: "warning\n[]\n", error: exactMissingDiagnostic),
  (exitCode: 125, output: "[]\n",
   error: "Error: registry.example/other:latest: image not known\n"),
  (exitCode: 125, output: "[]\n",
   error: "Error: " & BaseRef & ": image not known: extra\n"),
  (exitCode: 125, output: "[]\n",
   error: exactMissingDiagnostic & "Warning: later diagnostic\n"),
]:
  resetCase()
  setOriginalResult(
    rejected.exitCode,
    rejected.output,
    rejected.error,
  )
  let lookupFailure = fetch()
  doAssert lookupFailure.cancellation.isNone()
  doAssert lookupFailure.image.isNone()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])

for malformedLocal in [
  "not-json\n",
  "[{}]\n",
  inspection(id = "a".repeat(63)),
]:
  resetCase()
  setOriginalResult(0, malformedLocal, "")
  let malformedLookup = fetch()
  doAssert malformedLookup.cancellation.isNone()
  doAssert malformedLookup.image.isNone()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])

resetCase()
let selectedBeforeUnusedStage = fetch(effectiveStageCount = 1)
expectConfigBinding(selectedBeforeUnusedStage)
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
])

resetCase()
let neverLocal = fetch(policy = bppNever)
expectConfigBinding(neverLocal)
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
let neverAbsent = fetch(policy = bppNever)
doAssert neverAbsent.cancellation.isNone()
doAssert neverAbsent.image.isNone()
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
])

resetCase()
let newer = fetch(policy = bppNewer)
expectConfigBinding(newer)
expectCalls(@[
  @["pull", "--quiet", "--policy", "newer", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

for policy in [bppMissing, bppNever, bppNewer]:
  resetCase(ImageAId)
  let byId = fetch(image = ImageAId, policy = policy)
  expectConfigBinding(byId)
  expectCalls(@[
    @["image", "inspect", ImageAId, "--format", "json"],
  ])

resetCase(ImageAId)
let alwaysById = fetch(image = ImageAId, policy = bppAlways)
doAssert alwaysById.cancellation.isNone()
doAssert alwaysById.image.isNone()
expectCalls(@[])

resetCase()
let always = fetch(policy = bppAlways)
doAssert always.cancellation.isNone()
doAssert always.image.isSome()
doAssert always.image.get().binding.kind == bbRegistryDigest
doAssert always.image.get().binding.reference ==
  "registry.example/customer/base@" & DigestA
doAssert always.image.get().binding.imageId == ImageAId
doAssert always.image.get().binding.proofPlatform == cpLinuxAmd64
expectCalls(@[
  @["pull", "--quiet", "--policy", "always", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
  @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
    "registry.example/customer/base@" & DigestA],
])

let dockerHubRef = "index.docker.io/alpine:latest"
resetCase(dockerHubRef)
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @["docker.io/library/alpine@" & DigestA]),
)
let dockerHub = fetch(image = dockerHubRef, policy = bppAlways)
doAssert dockerHub.image.isSome()
doAssert dockerHub.image.get().binding.kind == bbRegistryDigest
doAssert dockerHub.image.get().binding.reference ==
  "docker.io/library/alpine@" & DigestA

resetCase(dockerHubRef)
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @[
    "index.docker.io/library/alpine@" & DigestA,
    "docker.io/library/alpine@" & DigestA,
  ]),
)
let dockerHubAliases = fetch(image = dockerHubRef, policy = bppAlways)
doAssert dockerHubAliases.image.isSome()
doAssert dockerHubAliases.image.get().binding.reference ==
  "index.docker.io/library/alpine@" & DigestA

resetCase("alpine:latest")
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @["mirror.example/team/alpine@" & DigestA]),
)
let shortUnique = fetch(image = "alpine:latest", policy = bppAlways)
doAssert shortUnique.image.isSome()
doAssert shortUnique.image.get().binding.kind == bbRegistryDigest
doAssert shortUnique.image.get().binding.reference ==
  "mirror.example/team/alpine@" & DigestA

resetCase("alpine:latest")
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @[
    "mirror.example/team/alpine@" & DigestA,
    "other.example/team/alpine@" & DigestA,
  ]),
)
let shortAmbiguous = fetch(image = "alpine:latest", policy = bppAlways)
doAssert shortAmbiguous.cancellation.isNone()
doAssert shortAmbiguous.image.isNone()
doAssert recordedCalls(log).len == 2

resetCase()
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @["other.example/customer/base@" & DigestA]),
)
let wrongRepository = fetch(policy = bppAlways)
doAssert wrongRepository.image.isNone()
doAssert recordedCalls(log).len == 2

resetCase()
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @[
    "localhost/customer/base@" & DigestA,
    "registry.example/customer/base@" & ChildDigest,
  ]),
)
let localDigestOnly = fetch(policy = bppAlways)
doAssert localDigestOnly.cancellation.isNone()
doAssert localDigestOnly.image.isNone()
doAssert recordedCalls(log).len == 2

for malformedInspection in [
  inspection(digest = ""),
  inspection(digest = "sha256:" & "1".repeat(63)),
  inspection(repoDigests = @[]),
  inspection(repoDigests = @[
    "registry.example/customer/base@sha256:" & "1".repeat(63),
  ]),
  inspection(repoDigests = @[
    "registry.example/customer/base@" & ChildDigest,
  ]),
]:
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", malformedInspection)
  let malformed = fetch(policy = bppAlways)
  doAssert malformed.cancellation.isNone()
  doAssert malformed.image.isNone()
  doAssert recordedCalls(log).len == 2

for malformedId in [
  "a".repeat(63),
  "sha256:" & ImageAId,
  "A".repeat(64),
]:
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(id = malformedId))
  let malformed = fetch(policy = bppNever)
  doAssert malformed.cancellation.isNone()
  doAssert malformed.image.isNone()

let malformedPullOutputs = [
  "sha256:" & ImageAId & "\n",
  ImageAId & "\n" & ImageBId & "\n",
  ImageAId & "\n\n",
  " " & ImageAId & "\n",
  "pulled\n",
]
for malformedOutput in malformedPullOutputs:
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
  putEnv("PODMAN_IMAGE_TEST_PULL_STDOUT", malformedOutput)
  let malformedMissing = fetch()
  doAssert malformedMissing.cancellation.isNone()
  doAssert malformedMissing.image.isNone()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
    @["pull", "--quiet", BaseRef],
  ])

  resetCase()
  putEnv("PODMAN_IMAGE_TEST_PULL_STDOUT", malformedOutput)
  let malformed = fetch(policy = bppNewer)
  doAssert malformed.cancellation.isNone()
  doAssert malformed.image.isNone()
  doAssert recordedCalls(log).len == 1

  resetCase()
  putEnv("PODMAN_IMAGE_TEST_PROOF_STDOUT", malformedOutput)
  let malformedProof = fetch(policy = bppAlways)
  doAssert malformedProof.cancellation.isNone()
  doAssert malformedProof.image.isNone()
  doAssert recordedCalls(log).len == 3

resetCase()
putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(id = ImageBId))
let changedAfterPull = fetch(policy = bppNewer)
doAssert changedAfterPull.cancellation.isNone()
doAssert changedAfterPull.image.isNone()
expectCalls(@[
  @["pull", "--quiet", "--policy", "newer", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(id = ImageBId))
let changedAfterMissingPull = fetch()
doAssert changedAfterMissingPull.cancellation.isNone()
doAssert changedAfterMissingPull.image.isNone()
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
putEnv("PODMAN_IMAGE_TEST_PULL_FAIL", "1")
let missingPullFailed = fetch()
doAssert missingPullFailed.cancellation.isNone()
doAssert missingPullFailed.image.isNone()
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
putEnv("PODMAN_IMAGE_TEST_INSPECT_FAIL", "1")
let missingInspectionFailed = fetch()
doAssert missingInspectionFailed.cancellation.isNone()
doAssert missingInspectionFailed.image.isNone()
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

for malformedSelectedInspection in [
  "not-json\n",
  "[]\n",
  inspection(id = "b".repeat(63)),
]:
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
  putEnv("PODMAN_IMAGE_TEST_INSPECT", malformedSelectedInspection)
  let malformedSelected = fetch()
  doAssert malformedSelected.cancellation.isNone()
  doAssert malformedSelected.image.isNone()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
    @["pull", "--quiet", BaseRef],
    @["image", "inspect", ImageAId, "--format", "json"],
  ])

for proofId in [ArmImageId, ImageBId]:
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_PROOF_STDOUT", proofId & "\n")
  let mismatched = fetch(policy = bppAlways)
  doAssert mismatched.cancellation.isNone()
  doAssert mismatched.image.isNone()
  doAssert recordedCalls(log).len == 3

resetCase()
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @[
    "registry.example/customer/base@" & DigestA,
    "registry.example/customer/child@" & ChildDigest,
  ]),
)
let indexDigest = fetch(policy = bppAlways)
doAssert indexDigest.image.isSome()
doAssert indexDigest.image.get().binding.reference ==
  "registry.example/customer/base@" & DigestA

resetCase()
putEnv("PODMAN_IMAGE_TEST_PROOF_FAIL", "1")
putEnv(
  "PODMAN_IMAGE_TEST_INSPECT",
  inspection(repoDigests = @[
    "registry.example/customer/base@" & DigestA,
    "registry.example/customer/child@" & ChildDigest,
  ]),
)
let staleDigest = fetch(policy = bppAlways)
doAssert staleDigest.cancellation.isNone()
doAssert staleDigest.image.isNone()
expectCalls(@[
  @["pull", "--quiet", "--policy", "always", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
  @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
    "registry.example/customer/base@" & DigestA],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_PULL_CANCEL", "1")
let initialCancelled = fetch(policy = bppAlways)
doAssert initialCancelled.image.isNone()
doAssert initialCancelled.cancellation.isSome()
doAssert initialCancelled.cancellation.get().kind == ceSignaled
doAssert recordedCalls(log).len == 1

resetCase()
putEnv("PODMAN_IMAGE_TEST_PROOF_CANCEL", "1")
let proofCancelled = fetch(policy = bppAlways)
doAssert proofCancelled.image.isNone()
doAssert proofCancelled.cancellation.isSome()
doAssert proofCancelled.cancellation.get().kind == ceSignaled
doAssert recordedCalls(log).len == 3

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_CANCEL", "1")
let missingLookupCancelled = fetch()
doAssert missingLookupCancelled.image.isNone()
doAssert missingLookupCancelled.cancellation.isSome()
doAssert missingLookupCancelled.cancellation.get().kind == ceSignaled
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
putEnv("PODMAN_IMAGE_TEST_PULL_CANCEL", "1")
let missingPullCancelled = fetch()
doAssert missingPullCancelled.image.isNone()
doAssert missingPullCancelled.cancellation.isSome()
doAssert missingPullCancelled.cancellation.get().kind == ceSignaled
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
])

resetCase()
putEnv("PODMAN_IMAGE_TEST_ORIGINAL_MISSING", "1")
putEnv("PODMAN_IMAGE_TEST_INSPECT_CANCEL", "1")
let missingInspectionCancelled = fetch()
doAssert missingInspectionCancelled.image.isNone()
doAssert missingInspectionCancelled.cancellation.isSome()
doAssert missingInspectionCancelled.cancellation.get().kind == ceSignaled
expectCalls(@[
  @["image", "inspect", BaseRef, "--format", "json"],
  @["pull", "--quiet", BaseRef],
  @["image", "inspect", ImageAId, "--format", "json"],
])

for target in ChalkPlatform:
  let arch = if target == cpLinuxAmd64: "amd64" else: "arm64"
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(architecture = arch))
  let multi = fetch(effectiveStageCount = 2, target = target)
  doAssert multi.image.isSome()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(architecture = arch))
  let explicit = fetch(commandPlatform = $target, target = target)
  doAssert explicit.image.isSome()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(architecture = arch))
  let declared = fetch(rootPlatform = parseDeclaredPlatform($target), target = target)
  doAssert declared.image.isSome()
  expectCalls(@[
    @["image", "inspect", BaseRef, "--format", "json"],
  ])
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_INSPECT", inspection(architecture = arch))
  let proven = fetch(policy = bppAlways, commandPlatform = $target, target = target)
  doAssert proven.image.isSome()
  doAssert proven.image.get().binding.proofPlatform == target
  expectCalls(@[
    @["pull", "--quiet", "--policy", "always", "--platform", $target, BaseRef],
    @["image", "inspect", ImageAId, "--format", "json"],
    @["pull", "--quiet", "--policy", "always", "--platform", $target,
      "registry.example/customer/base@" & DigestA],
  ])
  resetCase()
  putEnv("PODMAN_IMAGE_TEST_PROOF_CANCEL", "1")
  let cancelled = fetch(policy = bppAlways, target = target)
  doAssert cancelled.image.isNone()
  doAssert cancelled.cancellation.isSome()
  doAssert cancelled.cancellation.get().kind == ceSignaled
  doAssert recordedCalls(log).len == 3

removeFile(log)
removeDir(root)
