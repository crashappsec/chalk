## The build helper runs before configuration loading, including in scratch.
import std/[json, os, posix]

const podmanGuardCommand* = "__.podman_reserved_paths"

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
  # Refresh only a regular inherited executable paired with a recognizable mark.
  # In particular, lstat refuses dangling links and directories before any COPY.
  if binaryStatus != 0 or markStatus != 0 or
      not S_ISREG(binary.st_mode) or not S_ISREG(mark.st_mode):
    return false
  try:
    let value = parseFile(markPath)
    return value.kind == JObject and value.hasKey("MAGIC") and
      value["MAGIC"].kind == JString and
      value["MAGIC"].getStr() == "dadfedabbadabbed"
  except CatchableError:
    return false
