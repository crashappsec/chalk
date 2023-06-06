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

import tables, options, streams, strutils, endians, nimSHA2, ../config,
       ../plugins

const
  b64OffsetLoc = 0x28
  b32OffsetLoc = 0x20
  wsOffsetLoc  = 0x04
  is64BitVal   = char(0x02)
  bigEndianVal = char(0x02)
  elfMagic     = 0x7f454c46'u32
  elfSwapped   = 0x464c457f'u32


type CodecElf* = ref object of Codec

proc extractKeyMetadata(stream: FileStream, loc: string): ChalkObj =
  stream.setPosition(wsOffsetLoc)
  var
    is64Bit     = if stream.readChar() == is64BitVal: true else: false
    isBigEndian = if stream.readChar() == bigEndianVal: true else: false
    swap        = if is64Bit: swapEndian64 else: swapEndian32
    raw64:     uint64
    raw32:     uint32
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
    result = stream.loadChalkFromFStream(loc)
  else:
    result = newChalk(stream, loc)
    result.startOffset = stream.getPosition()

method scan*(self:   CodecElf,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =

  try:
    let magic = stream.readUint32()

    if magic != elfMagic and magic != elfSwapped: return none(ChalkObj)
    result = some(extractKeyMetadata(stream, loc))
  except: return none(ChalkObj)
  # This is usally a 0-length file and not worth a stack-trace.

method getUnchalkedHash*(self: CodecElf, chalk: ChalkObj): Option[string] =
  let s = chalk.acquireFileStream()
  if s.isNone(): return none(string)

  chalk.stream.setPosition(0)
  let toHash = chalk.stream.readStr(chalk.startOffset)
  return some(hashFmt($(toHash.computeSHA256())))

method getChalkInfo*(self: CodecElf, chalk: ChalkObj): ChalkDict =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeElf

method getPostChalkInfo*(self:  CodecElf,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeElf

method getNativeObjPlatforms*(s: CodecElf): seq[string] = @["linux"]

registerPlugin("elf", CodecElf())
