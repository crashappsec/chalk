import ../../src/podman/chalk_platform
import std/[
  options,
  os,
  sequtils,
  strutils,
]
import ../../src/docker/dockerfile
import ../../src/podman/binding
import ../../src/podman/cmdline
import ../../src/podman/exec as podman_exec
import ../../src/podman/image
import ../../src/podman/inject
import ../../src/podman/platform
import ../../src/podman/run
import ../../src/podman/types

const sourceDir = currentSourcePath().parentDir().parentDir().parentDir() / "src"
{.passc: "-I" & sourceDir.}

const
  BaseRef = "registry.example/chalk/identity:latest"
  ImageAId = repeat('a', 64)
  ImageBId = repeat('b', 64)
  ImageAInspect = "[{\"Id\":\"" & ImageAId &
    "\",\"Digest\":\"sha256:" & repeat('1', 64) &
    "\",\"RepoDigests\":[\"registry.example/chalk/identity@sha256:" &
    repeat('1', 64) &
    "\"],\"Os\":\"linux\",\"Architecture\":\"amd64\",\"Config\":{" &
    "\"Entrypoint\":[\"/image-a\"],\"Cmd\":[\"cmd-a\"]}}]"
  ContainerfileText = "FROM " & BaseRef & "\n"

proc fileArg(argv: seq[string]): string =
  for i, arg in argv:
    if arg == "--file" and i + 1 < len(argv):
      return argv[i + 1]
    if arg.startsWith("--file="):
      return arg["--file=".len .. ^1]
  return ""

proc runFakePodman() =
  let argv = commandLineParams()
  if len(argv) >= 3 and argv[0 .. 1] == @["image", "inspect"]:
    if argv[2] == BaseRef or argv[2] == ImageAId:
      stdout.write(ImageAInspect)
      writeFile(getEnv("PODMAN_BASE_BINDING_STATE"), ImageBId)
      quit(0)
    quit(125)

  if len(argv) > 0 and argv[0] == "build":
    let
      derived = readFile(fileArg(argv))
      consumed = if "FROM " & ImageAId in derived: ImageAId else: ImageBId
    writeFile(getEnv("PODMAN_BASE_BINDING_STATE"), consumed)
    quit(0)

  quit(99)

if getEnv("PODMAN_BASE_BINDING_CHILD") == "1":
  runFakePodman()

let
  root = getTempDir() / ("chalk-podman-base-binding-" & $getCurrentProcessId())
  context = root / "context"
  state = root / "state"
  fake = getAppFilename()

createDir(root)
createDir(context)
writeFile(context / "Containerfile", ContainerfileText)
writeFile(state, ImageAId)
putEnv("PODMAN_BASE_BINDING_CHILD", "1")
putEnv("PODMAN_BASE_BINDING_STATE", state)

let route = classifyPodmanArgs(@["build", "--pull=never", context])
doAssert route.kind == prInstrument
var spec = route.spec

let parsed = getFinalExecConfig(ContainerfileText)
doAssert parsed.config.isSome(), $parsed.errors
let config = parsed.config.get()

var cancellation = none(ChildResult)
let inspected = fetchBaseImage(
  fake,
  config.rootImage,
  cancellation,
  cpLinuxAmd64,
  spec.pullPolicy,
  spec.requestedPlatform,
)
doAssert cancellation.isNone()
doAssert inspected.isSome()

let base = decideFinalBase(config.rootImage, spec.requestedPlatform,
                           config.fromPlatform, inspected, target = cpLinuxAmd64)
doAssert base.kind == fbdAccept
let startup = podman_exec.planStartup(config, base.root)
doAssert startup.kind == podman_exec.sprPlan

spec.resolvedContext = context
spec.resolvedContainerfile = context / "Containerfile"
spec.containerfileText = ContainerfileText
spec.startup = config
spec.startupPlan = some(startup.plan)

let workspace = preparePodmanBuild(spec)
doAssert workspace.isSome()
let ws = workspace.get()
let injectedArgs = makeInjectedArgs(spec, ws)
doAssert injectedArgs[0 ..< len(spec.originalArgs)] == spec.originalArgs
let child = runAttached(fake, injectedArgs)
doAssert child.kind == ceExited
doAssert child.exitCode == 0
doAssert readFile(state) == ImageAId
doAssert ("FROM " & ImageAId & "\n") in ws.derivedText
doAssert "/image-a" in ws.derivedText
doAssert "cmd-a" in ws.derivedText

removeDir(ws.root)

proc chalkBlock(contextName: string): string =
  return
    "RUN [\"/bin/sh\", \"-c\", \"test -x / && " &
    "test ! -L /chalk && test ! -L /chalk.json && " &
    "{ { test ! -e /chalk && test ! -e /chalk.json; } || " &
    "grep -q dadfedabbadabbed /chalk.json; }\"]\n" &
    "COPY --from=" & contextName & " --chmod=0755 chalk /chalk\n" &
    "COPY --from=" & contextName & " --chmod=0444 chalk.json /chalk.json\n" &
    "ENTRYPOINT [\"/chalk\",\"exec\",\"--heartbeat\",\"--\"]\n"

proc derive(text: string,
            target = "",
            binding = BaseBinding(kind: bbConfigId, configId: ImageAId)): string =
  let parsed = getFinalExecConfig(text, target)
  doAssert parsed.config.isSome(), $parsed.errors
  let workspace = preparePodmanBuild(PodmanBuildSpec(
    containerfileText: text,
    startup:           parsed.config.get(),
    startupPlan:       some(podman_exec.StartupPlan(binding: binding)),
    resolvedContext:   context,
  ))
  doAssert workspace.isSome()
  let derived = workspace.get().derivedText
  result = derived
  removeDir(workspace.get().root)

proc expectDerived(text, target, expectedPrefix, expectedSuffix: string) =
  let derived = derive(text, target)
  let marker = derived.find("RUN [\"/bin/sh\"")
  doAssert marker >= 0
  let contextMarker = "COPY --from="
  let contextStart = derived.find(contextMarker, marker) + len(contextMarker)
  let contextStop = derived.find(" --chmod=0755", contextStart)
  doAssert contextStart >= len(contextMarker)
  doAssert contextStop > contextStart
  let expected = expectedPrefix &
    chalkBlock(derived[contextStart ..< contextStop]) & expectedSuffix
  doAssert derived == expected,
    "expected complete derived bytes:\n" & expected & "\ngot:\n" & derived

expectDerived(
  "FROM example.test/direct:old\nRUN echo direct\n",
  "",
  "FROM " & ImageAId & "\nRUN echo direct\n",
  "",
)
expectDerived(
  "FROM example.test/one:old AS root\nRUN echo root\n" &
    "FROM root AS final\nCMD [\"one\"]\n",
  "",
  "FROM " & ImageAId & " AS root\nRUN echo root\n" &
    "FROM root AS final\nCMD [\"one\"]\n",
  "",
)
expectDerived(
  "FROM example.test/two:old AS root\n" &
    "FROM root AS middle\n" &
    "FROM middle AS final\nCMD [\"two\"]\n",
  "final",
  "FROM " & ImageAId & " AS root\n" &
    "FROM root AS middle\n" &
    "FROM middle AS final\nCMD [\"two\"]\n",
  "",
)

let threeStages =
  "FROM example.test/selected:old AS first\nRUN echo first\n" &
  "FROM first AS middle\nRUN echo middle\n" &
  "FROM example.test/later:old AS later\nRUN echo later\n"
let middle = getFinalExecConfig(threeStages, "middle")
doAssert middle.config.isSome()
doAssert middle.config.get().effectiveStageCount == 2
expectDerived(
  threeStages,
  "middle",
  "FROM " & ImageAId & " AS first\nRUN echo first\n" &
    "FROM first AS middle\nRUN echo middle\n",
  "FROM example.test/later:old AS later\nRUN echo later\n",
)

let allStages = getFinalExecConfig(threeStages)
doAssert allStages.config.isSome()
doAssert allStages.config.get().effectiveStageCount == 3
expectDerived(
  threeStages,
  "later",
  "FROM example.test/selected:old AS first\nRUN echo first\n" &
    "FROM first AS middle\nRUN echo middle\n" &
    "FROM " & ImageAId & " AS later\nRUN echo later\n",
  "",
)

let selectedFirst = getFinalExecConfig(threeStages, "first")
doAssert selectedFirst.config.isSome()
doAssert selectedFirst.config.get().effectiveStageCount == 1
expectDerived(
  threeStages,
  "first",
  "FROM " & ImageAId & " AS first\nRUN echo first\n",
  "FROM first AS middle\nRUN echo middle\n" &
    "FROM example.test/later:old AS later\nRUN echo later\n",
)

expectDerived(
  "FROM --platform=linux/amd64 example.test/platform:old AS chosen\n" &
    "RUN echo platform\n",
  "",
  "FROM --platform=linux/amd64 " & ImageAId & " AS chosen\n" &
    "RUN echo platform\n",
  "",
)

expectDerived(
  "FROM example.test/crlf:old AS chosen\r\nRUN echo chosen\r\n" &
    "FROM example.test/other:old AS other\r\n",
  "chosen",
  "FROM " & ImageAId & " AS chosen\r\nRUN echo chosen\r\n",
  "FROM example.test/other:old AS other\r\n",
)

expectDerived(
  "FROM example.test/repeated:old AS chosen\nRUN echo chosen\n" &
    "FROM example.test/repeated:old AS other\nRUN echo other\n",
  "chosen",
  "FROM " & ImageAId & " AS chosen\nRUN echo chosen\n",
  "FROM example.test/repeated:old AS other\nRUN echo other\n",
)

expectDerived(
  "FROM base AS base\nRUN echo root\nFROM base AS final\n",
  "final",
  "FROM " & ImageAId & " AS base\nRUN echo root\nFROM base AS final\n",
  "",
)

let registryBinding = BaseBinding(
  kind:          bbRegistryDigest,
  reference:     "registry.example/customer/base@sha256:" & repeat('1', 64),
  imageId:       ImageAId,
  proofPlatform: cpLinuxAmd64,
)
let registryText =
  "FROM --platform=linux/amd64 " & BaseRef & " AS chosen\n" &
  "RUN echo chosen\nFROM " & BaseRef & " AS sibling\n"
let registryDerived = derive(registryText, "chosen", registryBinding)
doAssert registryDerived.startsWith(
  "FROM --platform=linux/amd64 " & registryBinding.reference &
    " AS chosen\nRUN echo chosen\n",
)
doAssert registryDerived.endsWith("FROM " & BaseRef & " AS sibling\n")

let directParsed = getFinalExecConfig("FROM example.test/unbound:old\n")
doAssert directParsed.config.isSome()
let unbound = preparePodmanBuild(PodmanBuildSpec(
  containerfileText: "FROM example.test/unbound:old\n",
  startup:           directParsed.config.get(),
  startupPlan:       some(podman_exec.StartupPlan()),
  resolvedContext:   context,
))
doAssert unbound.isNone()

let externalAsScratch = preparePodmanBuild(PodmanBuildSpec(
  containerfileText: "FROM example.test/unbound:old\n",
  startup:           directParsed.config.get(),
  startupPlan:       some(podman_exec.StartupPlan(
    binding: BaseBinding(kind: bbScratch),
  )),
  resolvedContext:   context,
))
doAssert externalAsScratch.isNone()

let scratchText = "FROM scratch\n"
let scratchParsed = getFinalExecConfig(scratchText)
doAssert scratchParsed.config.isSome()
let scratchAsImage = preparePodmanBuild(PodmanBuildSpec(
  containerfileText: scratchText,
  startup:           scratchParsed.config.get(),
  startupPlan:       some(podman_exec.StartupPlan(
    binding: BaseBinding(kind: bbConfigId, configId: ImageAId),
  )),
  resolvedContext:   context,
))
doAssert scratchAsImage.isNone()

var staleConfig = directParsed.config.get()
staleConfig.rootImageSpan = some(SourceInterval(
  start: staleConfig.rootImageSpan.get().start + 1,
  stop:  staleConfig.rootImageSpan.get().stop,
))
let staleInterval = preparePodmanBuild(PodmanBuildSpec(
  containerfileText: "FROM example.test/unbound:old\n",
  startup:           staleConfig,
  startupPlan:       some(podman_exec.StartupPlan(
    binding: BaseBinding(kind: bbConfigId, configId: ImageAId),
  )),
  resolvedContext:   context,
))
doAssert staleInterval.isNone()

let variableText = "ARG BASE=example.test/base:old\nFROM $BASE\n"
let variableParsed = getFinalExecConfig(variableText)
doAssert variableParsed.config.isSome()
let variableWorkspace = preparePodmanBuild(PodmanBuildSpec(
  containerfileText: variableText,
  startup:           variableParsed.config.get(),
  startupPlan:       some(podman_exec.StartupPlan(
    binding: BaseBinding(kind: bbConfigId, configId: ImageAId),
  )),
  resolvedContext:   context,
))
doAssert variableWorkspace.isNone()

for unsupported in [
  "FROM " & "\\" & "\n  example.test/base:old\n",
  "FROM example.test/base\\:old\n",
  "FROM \"example.test/base:old\"\n",
]:
  let refused = getFinalExecConfig(unsupported)
  doAssert refused.config.isNone(), unsupported
  doAssert refused.issue.isSome(), unsupported

let ambiguousTarget = getFinalExecConfig(
  "FROM example.test/one:old AS chosen\n" &
    "FROM example.test/two:old AS chosen\n",
  "chosen",
)
doAssert ambiguousTarget.config.isNone()
doAssert ambiguousTarget.issue.isSome()
doAssert ambiguousTarget.issue.get().kind == cfikTargetUnavailable

for unrelated in [
  "FROM example.test/unused\\:old AS unused\n" &
    "FROM example.test/chosen:old AS chosen\n",
  "FROM example.test/chosen:old AS chosen\n" &
    "FROM example.test/later\\:old AS later\n",
]:
  let selected = getFinalExecConfig(unrelated, "chosen")
  doAssert selected.config.isSome(), $selected.errors

let explicitRoute = classifyPodmanArgs(@[
  "build", "--platform", "linux/amd64", "--pull=never", context,
])
doAssert explicitRoute.kind == prInstrument
var explicitSpec = explicitRoute.spec
explicitSpec.resolvedContext = context
explicitSpec.resolvedContainerfile = context / "Containerfile"
explicitSpec.containerfileText = ContainerfileText
explicitSpec.startup = config
explicitSpec.startupPlan = some(startup.plan)
let explicitWorkspace = preparePodmanBuild(explicitSpec)
doAssert explicitWorkspace.isSome()
let explicitArgs = makeInjectedArgs(explicitSpec, explicitWorkspace.get())
doAssert explicitArgs[0 ..< len(explicitSpec.originalArgs)] ==
  explicitSpec.originalArgs
doAssert explicitArgs.countIt(it == "--platform") == 1
doAssert explicitArgs.countIt(it == "--pull=never") == 1
removeDir(explicitWorkspace.get().root)

removeDir(root)
