import std/[
  json,
  os,
  posix,
  sequtils,
  strutils,
]
import ../../src/podman/build
import ../../src/podman/run
import ../../src/podman/types

const
  sourceDir = currentSourcePath().parentDir().parentDir().parentDir() / "src"
  ImageId = "a".repeat(64)
  Digest = "sha256:" & "1".repeat(64)

{.passc: "-I" & sourceDir.}

proc linkInsertCommand(path: seq[string])
    {.exportc: "runCmdInsert", cdecl.} =
  doAssert false, "runCmdInsert unexpectedly called with " & $path

proc linkExtractCommand(path: seq[string])
    {.exportc: "runCmdExtract", cdecl.} =
  doAssert false, "runCmdExtract unexpectedly called with " & $path

proc linkDeleteCommand(path: seq[string])
    {.exportc: "runCmdDelete", cdecl.} =
  doAssert false, "runCmdDelete unexpectedly called with " & $path

proc writeCall(path: string, argv: seq[string]) =
  var encoded = newJArray()
  for arg in argv:
    encoded.add(%arg)
  let stream = open(path, fmAppend)
  stream.writeLine($encoded)
  stream.close()

proc fakePodman() =
  let argv = commandLineParams()
  let scenario = getEnv("PODMAN_BINDING_FALLBACK_SCENARIO")
  writeCall(getEnv("PODMAN_BINDING_FALLBACK_LOG"), argv)
  if argv == @["info", "--format", "json"]:
    stdout.write(
      """{"host":{"os":"linux","arch":"amd64","serviceIsRemote":false,"buildahVersion":"1.43.1"}}""",
    )
    quit(0)
  if argv.len >= 2 and argv[0 .. 1] == @["pull", "--quiet"]:
    let proof = "@sha256:" in argv[^1]
    if (scenario == "initial-cancel" and not proof) or
        (scenario == "proof-cancel" and proof):
      discard kill(getpid(), SIGTERM)
      quit(99)
    stdout.write(ImageId & "\n")
    quit(0)
  if argv.len >= 3 and argv[0 .. 1] == @["image", "inspect"]:
    let repoDigests =
      if scenario == "ambiguous":
        %* [
          "mirror.example/library/alpine@" & Digest,
          "other.example/library/alpine@" & Digest,
        ]
      else:
        %* ["mirror.example/library/alpine@" & Digest]
    stdout.write($(%* [{
      "Id": ImageId,
      "Digest": Digest,
      "RepoDigests": repoDigests,
      "Os": "linux",
      "Architecture": "amd64",
      "Config": {
        "Entrypoint": ["/image-a"],
        "Cmd": ["cmd-a"],
      },
    }]))
    quit(0)
  if argv.len > 0 and argv[0] == "build":
    let iidFlag = argv.find("--iidfile")
    if iidFlag >= 0 and iidFlag + 1 < len(argv):
      writeFile(argv[iidFlag + 1], "native\n")
    quit(0)
  quit(99)

proc writeFakeLinuxAmd64(path: string) =
  var header = newString(20)
  header[0] = '\x7f'
  header[1] = 'E'
  header[2] = 'L'
  header[3] = 'F'
  header[4] = '\x02'
  header[5] = '\x01'
  header[6] = '\x01'
  header[18] = '\x3e'
  header[19] = '\x00'
  writeFile(path, header)

proc originalArgs(): seq[string] =
  result = @[
    "build",
    "--pull=always",
  ]
  if getEnv("PODMAN_BINDING_FALLBACK_EXPLICIT_PLATFORM") == "1":
    result.add(["--platform", "linux/amd64"])
  result.add([
    "--tag", "keep.example/customer/app:test",
    "--iidfile", getEnv("PODMAN_BINDING_FALLBACK_IID"),
    getEnv("PODMAN_BINDING_FALLBACK_CONTEXT"),
  ])

case getEnv("PODMAN_BINDING_FALLBACK_MODE")
of "fake":
  fakePodman()
of "runner":
  putEnv("PODMAN_BINDING_FALLBACK_MODE", "fake")
  let status = runPodmanCommand(
    getAppFilename(),
    originalArgs(),
    getEnv("PODMAN_BINDING_FALLBACK_ELF"),
  )
  writeFile(getEnv("PODMAN_BINDING_FALLBACK_STATUS"), $status)
  quit(0)
else:
  discard

proc recordedCalls(path: string): seq[seq[string]] =
  for line in readFile(path).splitLines():
    if line == "":
      continue
    var args: seq[string]
    for value in parseJson(line):
      args.add(value.getStr())
    result.add(args)

let
  root = getTempDir() / ("chalk-podman-binding-fallback-" &
    $getCurrentProcessId())
  context = root / "context"
  log = root / "calls.jsonl"
  iid = root / "customer.iid"
  statusPath = root / "status"
  fakeElf = root / "chalk-linux-amd64"

createDir(root)
createDir(context)
writeFile(context / "Containerfile", "FROM alpine:latest\nCMD [\"run\"]\n")
writeFile(log, "")
writeFakeLinuxAmd64(fakeElf)
putEnv("PODMAN_BINDING_FALLBACK_LOG", log)
putEnv("PODMAN_BINDING_FALLBACK_IID", iid)
putEnv("PODMAN_BINDING_FALLBACK_CONTEXT", context)
putEnv("PODMAN_BINDING_FALLBACK_ELF", fakeElf)
putEnv("PODMAN_BINDING_FALLBACK_STATUS", statusPath)
putEnv("PODMAN_BINDING_FALLBACK_SCENARIO", "ambiguous")
putEnv("PODMAN_BINDING_FALLBACK_EXPLICIT_PLATFORM", "1")
putEnv("PODMAN_BINDING_FALLBACK_MODE", "runner")

let child = runAttached(getAppFilename(), @[])
doAssert child.kind == ceExited
doAssert child.exitCode == 0

let calls = recordedCalls(log)
doAssert calls == @[
  @["info", "--format", "json"],
  @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
    "alpine:latest"],
  @["image", "inspect", ImageId, "--format", "json"],
  originalArgs(),
]
doAssert calls.countIt(it.len > 0 and it[0] == "build") == 1
doAssert "--build-context" notin calls[^1]
doAssert calls[^1].countIt(it == "--iidfile") == 1
doAssert calls[^1].countIt(it == "--tag") == 1
doAssert readFile(iid) == "native\n"

writeFile(log, "")
removeFile(iid)
putEnv("PODMAN_BINDING_FALLBACK_EXPLICIT_PLATFORM", "0")
putEnv("PODMAN_BINDING_FALLBACK_MODE", "runner")
let defaultPlatformChild = runAttached(getAppFilename(), @[])
doAssert defaultPlatformChild.kind == ceExited
doAssert defaultPlatformChild.exitCode == 0
let defaultPlatformCalls = recordedCalls(log)
doAssert defaultPlatformCalls == @[
  @["info", "--format", "json"],
  @["pull", "--quiet", "--policy", "always", "alpine:latest"],
  @["image", "inspect", ImageId, "--format", "json"],
  originalArgs(),
]
doAssert "--platform" notin defaultPlatformCalls[^1]
doAssert "--build-context" notin defaultPlatformCalls[^1]
doAssert readFile(iid) == "native\n"

putEnv("PODMAN_BINDING_FALLBACK_EXPLICIT_PLATFORM", "1")
for scenario in ["initial-cancel", "proof-cancel"]:
  writeFile(log, "")
  if fileExists(iid):
    removeFile(iid)
  if fileExists(statusPath):
    removeFile(statusPath)
  putEnv("PODMAN_BINDING_FALLBACK_SCENARIO", scenario)
  putEnv("PODMAN_BINDING_FALLBACK_MODE", "runner")
  let cancelled = runAttached(getAppFilename(), @[])
  doAssert cancelled.kind == ceExited
  doAssert cancelled.exitCode == 0
  doAssert readFile(statusPath) == "143"
  let cancelledCalls = recordedCalls(log)
  doAssert cancelledCalls.countIt(it.len > 0 and it[0] == "build") == 0
  doAssert not fileExists(iid)
  if scenario == "initial-cancel":
    doAssert cancelledCalls == @[
      @["info", "--format", "json"],
      @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
        "alpine:latest"],
    ]
  else:
    doAssert cancelledCalls == @[
      @["info", "--format", "json"],
      @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
        "alpine:latest"],
      @["image", "inspect", ImageId, "--format", "json"],
      @["pull", "--quiet", "--policy", "always", "--platform", "linux/amd64",
        "mirror.example/library/alpine@" & Digest],
    ]

removeFile(log)
removeFile(statusPath)
removeFile(fakeElf)
removeDir(root)
