import std/os
import ../../src/confload
import ../../src/chalkjson
import ../../src/podman/scan
import ../../src/types

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

proc main() =
  loadAllConfigs()

  let extracted = ChalkDict()
  extracted["CHALK_ID"] = pack("chalk-lineage-id")
  extracted["DOCKER_TAGS"] = pack(@["registry.example/team/app:built"])
  extracted["DOCKER_PLATFORM"] = pack("attacker/os")
  extracted["PODMAN_IMAGE_ID"] = pack("sha256:attacker-image")
  extracted["_IMAGE_CONFIG_DIGEST"] = pack("attacker-config")
  extracted["_IMAGE_USER"] = pack("attacker-user")
  extracted["_OPERATION"] = pack("attacker-operation-name")
  extracted["_OP_ARGV"] = pack(@["attacker-operation"])
  extracted["_PROCESS_ARGV"] = pack(@["attacker-process"])
  extracted["_REPO_TAGS"] = pack(ChalkDict())
  extracted["X_UNKNOWN_ATTACKER_FIELD"] = pack("attacker-unknown")

  let current = ChalkDict()
  current["DOCKER_PLATFORM"] = pack("linux/arm64")
  current["PODMAN_IMAGE_ID"] = pack("sha256:engine-image")
  current["_IMAGE_CONFIG_DIGEST"] = pack("engine-config")
  current["_IMAGE_USER"] = pack("engine-user")

  let before = pack(extracted).boxToJson()
  let projected = projectPodmanMarkHistory(extracted, current)
  assertEq(pack(extracted).boxToJson(), before)
  assertEq(unpack[string](projected["CHALK_ID"]), "chalk-lineage-id")
  assertEq(
    unpack[seq[string]](projected["DOCKER_TAGS"]),
    @["registry.example/team/app:built"],
  )
  for key in [
    "DOCKER_PLATFORM",
    "PODMAN_IMAGE_ID",
    "_IMAGE_CONFIG_DIGEST",
    "_IMAGE_USER",
    "_OPERATION",
    "_OP_ARGV",
    "_PROCESS_ARGV",
    "_REPO_TAGS",
    "X_UNKNOWN_ATTACKER_FIELD",
  ]:
    doAssert key notin projected, key

  let missingInspection = ChalkDict()
  let withoutTruth = projectPodmanMarkHistory(extracted, missingInspection)
  doAssert "DOCKER_PLATFORM" notin withoutTruth
  doAssert "PODMAN_IMAGE_ID" notin withoutTruth
  doAssert "_IMAGE_CONFIG_DIGEST" notin withoutTruth
  doAssert "_IMAGE_USER" notin withoutTruth

  let wrongTypes = ChalkDict()
  wrongTypes["CHALK_ID"] = pack(@["not", "a", "string"])
  wrongTypes["DOCKER_TAGS"] = pack("not-a-list")
  let rejectedTypes = projectPodmanMarkHistory(wrongTypes, ChalkDict())
  doAssert "CHALK_ID" notin rejectedTypes
  doAssert "DOCKER_TAGS" notin rejectedTypes

main()
