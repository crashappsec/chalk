## A codec for ELF binaries. Currently, this takes the 'fast and easy'
## approach, choosing the end of the ELF file, instead of inserting a
## real section.
##
## We should eventually add another plugin that takes the other
## approach, because some people might prefer to have more 'robust'
## insertions.  By that, I mean our current approach can be accidentally
## removed via the 'strip' command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import  endians, nimSHA2, ../config, ../util, ../plugin_api

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
                      stream       = stream,
                      codec        = codec,
                      resourceType = {ResourceFile})
    result.startOffset = stream.getPosition()

proc elfScan*(self: Plugin, loc: string): Option[ChalkObj] {.cdecl.} =
  var
    stream: FileStream

  try:
    stream    = newFileStream(loc)

    if stream == nil:
      return none(ChalkObj)

    let magic = stream.readUint32()

    if magic != elfMagic and magic != elfSwapped:
      stream.close()
      return none(ChalkObj)

    result = some(self.extractKeyMetadata(stream, loc))
  except:
    if stream != nil:
      stream.close()

    return none(ChalkObj)
  # This is usally a 0-length file and not worth a stack-trace.

proc elfGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                        Option[string] {.cdecl.} =
  chalk.chalkUseStream():
    let toHash = stream.readStr(chalk.startOffset)
    return some(hashFmt($(toHash.computeSHA256())))

proc elfGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeElf

proc elfGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeElf

proc loadCodecElf*() =
  newCodec("elf",
         nativeObjPlatforms = @["linux"],
         scan               = ScanCb(elfScan),
         getUnchalkedHash   = UnchalkedHashCb(elfGetUnchalkedHash),
         ctArtCallback      = ChalkTimeArtifactCb(elfGetChalkTimeArtifactInfo),
         rtArtCallback      = RunTimeArtifactCb(elfgetRunTimeArtifactInfo))
