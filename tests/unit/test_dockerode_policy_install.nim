import std/[
  json,
  os,
  osproc,
  strutils,
  tempfiles,
]
import ../../src/dockerode_post_push/policy_install
import ../../src/utils/[
  file_string_stream,
  files,
]

proc expectValueError(action: proc()) =
  var rejected = false
  try:
    action()
  except ValueError:
    rejected = true
  doAssert rejected

proc main() =
  let
    parent = createTempDir("chalk-policy-test-", "")
    root = parent / "policy"
    binary = getAppFilename()
    binaryHash = newFileStringStream(binary).sha256Hex()
  defer:
    removeDir(parent)

  let activation = installDockerodePolicy(root, binary)
  doAssert activation == root / "releases" / binaryHash / "activate.sh"
  doAssert installDockerodePolicy(root, binary) == activation
  doAssert getFilePermissions(root) == chmodPermissions("0700")
  doAssert getFilePermissions(root / "dockerode-diagnostics.jsonl") ==
    chmodPermissions("0600")
  doAssert getFilePermissions(activation.parentDir()) == chmodPermissions("0555")
  doAssert newFileStringStream(activation.parentDir() / "chalk").sha256Hex() == binaryHash
  doAssert parseJson(readFile(activation.parentDir() / "manifest.json"))["schema"].getStr() ==
    "chalk-dockerode-policy/v1"
  for kind, path in walkDir(root / "releases"):
    doAssert not path.extractFilename().startsWith(".staging-")

  let shell = execCmdEx(
    "NODE_OPTIONS='--trace-warnings' /bin/sh -c '. " & quoteShell(activation) &
    "; printf \"%s\\n%s\\n%s\\n\" \"$NODE_OPTIONS\" \"$CHALK_DOCKERODE_CHALK\" \"$CHALK_DOCKERODE_LOG\"'",
  )
  doAssert shell.exitCode == 0, readFile(activation) & shell.output
  let values = shell.output.strip().splitLines()
  doAssert values[0].startsWith("--trace-warnings --require=\"")
  doAssert values[0].contains(activation.parentDir() / "loader" / "register.cjs")
  doAssert values[1] == activation.parentDir() / "chalk"
  doAssert values[2] == root / "dockerode-diagnostics.jsonl"

  expectValueError(proc() = discard installDockerodePolicy("relative", binary))

  let badPermissions = parent / "bad-permissions"
  createDir(badPermissions)
  setFilePermissions(badPermissions, chmodPermissions("0755"))
  expectValueError(proc() = discard installDockerodePolicy(badPermissions, binary))

  let actualRoot = parent / "actual"
  createDir(actualRoot)
  setFilePermissions(actualRoot, chmodPermissions("0700"))
  let linkedRoot = parent / "linked"
  createSymlink(actualRoot, linkedRoot)
  expectValueError(proc() = discard installDockerodePolicy(linkedRoot, binary))

  let runtime = activation.parentDir() / "loader" / "runtime.cjs"
  setFilePermissions(runtime, chmodPermissions("0644"))
  writeFile(runtime, readFile(runtime) & "corrupt")
  setFilePermissions(runtime, chmodPermissions("0444"))
  expectValueError(proc() = discard installDockerodePolicy(root, binary))

  let incompleteRoot = parent / "incomplete"
  let incompleteActivation = installDockerodePolicy(incompleteRoot, binary)
  let loader = incompleteActivation.parentDir() / "loader"
  setFilePermissions(loader, chmodPermissions("0755"))
  removeFile(loader / "runtime.cjs")
  setFilePermissions(loader, chmodPermissions("0555"))
  expectValueError(proc() = discard installDockerodePolicy(incompleteRoot, binary))

main()
