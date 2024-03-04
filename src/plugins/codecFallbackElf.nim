##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This was our prototype for the ELF plugin. It takes advantage of
## the fact that you can always add garbage to the end on an ELF
## binary; it will never get used.
##
## However, it can get stripped, or removed due to all sorts of other
## transformations you might want to do. So it's not a great long-term
## approach.
##
## Still, there are a couple of cases where the current ELF codec
## 'gives up', because it doesn't understand the structure of the ELF
## file.
##
## We believe these are conditions that don't exist in the real world,
## but if we're wrong, it's good to have a fallback!
##
## This should *not* ever take higher priority than the proper ELF
## codec; doing so will break compatibility. The built-in
## configuration enforces this, but please don't ever change it!

import std/endians
import ".."/[config, util, plugin_api]

const
  b64OffsetLoc = 0x28
  b32OffsetLoc = 0x20
  wsOffsetLoc  = 0x04
  is64BitVal   = char(0x02)
  bigEndianVal = char(0x02)
  elfMagic     = 0x7f454c46'u32
  elfSwapped   = 0x464c457f'u32


proc extractKeyMetadata(codec: Plugin, stream: FileStream, loc: string):
                       ChalkObj =
  stream.setPosition(wsOffsetLoc)
  var
    is64Bit     = if stream.readChar() == is64BitVal: true else: false
    isBigEndian = if stream.readChar() == bigEndianVal: true else: false
    swap        = if is64Bit: swapEndian64 else: swapEndian32
    raw64:             uint64
    raw32:             uint32
    rawBytes, shStLoc: pointer
    shStart, offset:   int

  if is64Bit:
    stream.setPosition(b64OffsetLoc)
    raw64    = stream.readUint64()
    rawBytes = addr(raw64)
    shStart  = int(raw64)
  else:
    stream.setPosition(b32OffsetLoc)
    raw32    = stream.readUint32()
    rawBytes = addr(raw32)
    shStart  = int(raw32)

  when system.cpuEndian == bigEndian:
    if not isBigEndian:
      swap(addr(shStLoc), addr(rawBytes))
      shStart = if is64Bit: raw64 else: raw32
  else:
    if isBigEndian:
      swap(addr(shStLoc), addr(rawBytes))
      shStart = if is64Bit: int(raw64) else: int(raw32)

  stream.setPosition(int(shStart))
  let
    secHdr = stream.readAll()
    offset1 = secHdr.find(magicUTF8)

  if offset1 != -1:
    offset = int(shStart) + offset1
    stream.setPosition(offset)
    result = codec.loadChalkFromFStream(stream, loc)
  else:
    result = newChalk(name         = loc,
                      fsRef        = loc,
                      codec        = codec,
                      resourceType = {ResourceFile})
    result.startOffset = stream.getPosition()

proc fbScan*(self: Plugin, loc: string): Option[ChalkObj] {.cdecl.} =
  withFileStream(loc, strict = true):
    try:
      let magic = stream.readUint32()
      if magic != elfMagic and magic != elfSwapped:
        return none(ChalkObj)

      return some(self.extractKeyMetadata(stream, loc))
    except:
      # This is usally a 0-length file and not worth a stack-trace.
      return none(ChalkObj)

proc fbGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                        Option[string] {.cdecl.} =
  withFileStream(chalk.fsRef, strict = true):
    let toHash = stream.readStr(chalk.startOffset)
    return some(toHash.sha256Hex())

proc fbGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeElf

proc fbGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeElf

proc loadCodecFallbackElf*() =
  newCodec("elf_last_resort",
         nativeObjPlatforms = @["linux"],
         scan               = ScanCb(fbScan),
         getUnchalkedHash   = UnchalkedHashCb(fbGetUnchalkedHash),
         ctArtCallback      = ChalkTimeArtifactCb(fbGetChalkTimeArtifactInfo),
         rtArtCallback      = RunTimeArtifactCb(fbgetRunTimeArtifactInfo))
