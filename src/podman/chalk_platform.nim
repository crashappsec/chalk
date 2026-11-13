import std/options
import "../docker"/ids
from "../types" import DockerPlatform

type ChalkPlatform* = enum
  cpLinuxAmd64 = "linux/amd64"
  cpLinuxArm64 = "linux/arm64"

proc parseCommandPlatform*(value: string): Option[ChalkPlatform] =
  case value
  of "linux/amd64": return some(cpLinuxAmd64)
  of "linux/arm64": return some(cpLinuxArm64)
  else: return none(ChalkPlatform)

proc chalkPlatformOf*(platform: DockerPlatform): Option[ChalkPlatform] =
  let normalized = platform.normalize()
  if normalized.os != "linux":
    return none(ChalkPlatform)
  case normalized.architecture
  of "amd64": return some(cpLinuxAmd64)
  of "arm64": return some(cpLinuxArm64)
  else: return none(ChalkPlatform)

proc elfPlatform*(header: openArray[char]): Option[ChalkPlatform] =
  if header.len < 20 or header[0] != '\x7f' or header[1] != 'E' or
      header[2] != 'L' or header[3] != 'F' or header[4] != '\x02' or
      header[5] != '\x01' or header[6] != '\x01' or header[19] != '\x00':
    return none(ChalkPlatform)
  case header[18]
  of '\x3e': return some(cpLinuxAmd64)
  of '\xb7': return some(cpLinuxArm64)
  else: return none(ChalkPlatform)

proc readChalkPlatform*(path: string): Option[ChalkPlatform] =
  var file: File
  if not file.open(path):
    return none(ChalkPlatform)
  try:
    var header: array[20, char]
    if file.readBuffer(addr header[0], header.len) != header.len:
      return none(ChalkPlatform)
    return elfPlatform(header)
  finally:
    file.close()
