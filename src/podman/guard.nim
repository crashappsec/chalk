## The build helper runs before configuration loading, including in scratch.
import std/[json, os, posix]

const podmanGuardCommand* = "__.podman_reserved_paths"

proc recognizableMark(value: JsonNode): bool =
  return value != nil and value.kind == JObject and value.hasKey("MAGIC") and
    value["MAGIC"].kind == JString and
    value["MAGIC"].getStr() == "dadfedabbadabbed"

proc recognizablePodmanMark*(value: JsonNode): bool =
  if recognizableMark(value):
    return true
  if value == nil or value.kind != JObject or value.hasKey("CHALK_ID") or
      not value.hasKey("EMBEDDED_CHALK"):
    return false
  let embedded = value["EMBEDDED_CHALK"]
  return embedded.kind == JArray and embedded.len == 1 and
    recognizableMark(embedded[0])

proc reservedPathsAvailable*(root = "/"): bool =
  var binary, mark: Stat
  let
    binaryPath = root / "chalk"
    markPath = root / "chalk.json"
    binaryStatus = lstat(binaryPath.cstring, binary)
    binaryError = errno
    markStatus = lstat(markPath.cstring, mark)
    markError = errno
  if binaryStatus != 0 and binaryError != ENOENT:
    return false
  if markStatus != 0 and markError != ENOENT:
    return false
  if binaryStatus != 0 and markStatus != 0:
    return true
  # Docker can mark an image without installing a wrapper executable. Accept
  # that inherited mark, but refuse links and directories before either COPY.
  if markStatus != 0 or not S_ISREG(mark.st_mode) or
      (binaryStatus == 0 and not S_ISREG(binary.st_mode)):
    return false
  try:
    let value = parseFile(markPath)
    return recognizablePodmanMark(value)
  except CatchableError:
    return false
