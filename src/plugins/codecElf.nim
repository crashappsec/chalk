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

import options, streams, strutils, endians
import nimSHA2, ../types, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

const
  b64OffsetLoc = 0x28
  b32OffsetLoc = 0x20
  wsOffsetLoc  = 0x04
  is64BitVal   = char(0x02)
  bigEndianVal = char(0x02)
  elfMagic     = 0x7f454c46'u32
  elfSwapped   = 0x464c457f'u32


type CodecElf* = ref object of Codec

proc extractKeyMetadata*(self: CodecElf, obj: ChalkObj): bool =
  if obj.stream == nil:
    return false
  obj.stream.setPosition(wsOffsetLoc)
  let
    is64Bit = if obj.stream.readChar() == is64BitVal:
                true
              else:
                false
    isBigEndian = if obj.stream.readChar() == bigEndianVal:
                    true
                  else:
                    false

  var rawBytes: uint64
  var shStart:  uint64
  var present:  bool
  var offset:   int

  if is64Bit:
    obj.flags.incl(Arch64Bit)
    obj.stream.setPosition(b64OffsetLoc)
    rawBytes = obj.stream.readUint64()

    when system.cpuEndian == bigEndian:
      if not isBigEndian:
        swapEndian64(addr(shStart), addr(rawBytes))
      else:
        shStart = rawBytes
    else:
      if isBigEndian:
        swapEndian64(addr(shStart), addr(rawBytes))
      else:
        shStart = rawBytes

    obj.stream.setPosition(int(shStart))
    let
      secHdr = obj.stream.readAll()
      offset1 = secHdr.find(magicUTF8)

    if offset1 != -1:
      offset = int(shStart) + offset1
      present = true
    else:
      offset = int(shStart) + secHdr.len()
      present = false

  obj.primary = ChalkPoint(startOffset: offset, present: present)

  return true

method scan*(self: CodecElf, obj: ChalkObj): bool =
  obj.stream.setPosition(0)

  try: # Reads can fail, for instance on 0-byte files.
    let magic = obj.stream.readUint32()

    if magic != elfMagic and magic != elfSwapped:
      return false

    result = self.extractKeyMetadata(obj)
  except:
    result = false

method handleWrite*(self:    CodecElf,
                    obj:     ChalkObj,
                    ctx:     Stream,
                    pre:     string,
                    encoded: Option[string],
                    post:    string) =
  ctx.write(pre)
  if encoded.isSome():
    ctx.write(encoded.get())

method getArtifactHash*(self: CodecElf, obj: ChalkObj): string =
  var shaCtx = initSHA[SHA256]()
  let offset = obj.primary.startOffset

  obj.stream.setPosition(0)
  shaCtx.update(obj.stream.readStr(offset))

  return $shaCtx.final()

registerPlugin("elf", CodecElf())
