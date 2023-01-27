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
import nimSHA2, ../config, ../plugins

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

proc extractKeyMetadata*(self: CodecElf, sami: SamiObj): bool =
  if sami.stream == nil:
    return false
  sami.stream.setPosition(wsOffsetLoc)
  let
    is64Bit = if sami.stream.readChar() == is64BitVal:
                true
              else:
                false
    isBigEndian = if sami.stream.readChar() == bigEndianVal:
                    true
                  else:
                    false

  var rawBytes: uint64
  var shStart:  uint64
  var present:  bool
  var offset:   int

  if isBigEndian:
    sami.flags.incl(BigEndian)

  if is64Bit:
    sami.flags.incl(Arch64Bit)
    sami.stream.setPosition(b64OffsetLoc)
    rawBytes = sami.stream.readUint64()

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

    sami.stream.setPosition(int(shStart))
    let
      secHdr = sami.stream.readAll()
      offset1 = secHdr.find(magicUTF8)

    if offset1 != -1:
      offset = int(shStart) + offset1
      present = true
    else:
      offset = int(shStart) + secHdr.len()
      present = false

  sami.primary = SamiPoint(startOffset: offset, present: present)

  return true

method scan*(self: CodecElf, sami: SamiObj): bool =
  sami.stream.setPosition(0)

  try: # Reads can fail, for instance on 0-byte files.
    let magic = sami.stream.readUint32()

    if magic != elfMagic and magic != elfSwapped:
      return false

    result = self.extractKeyMetadata(sami)
  except:
    result = false

method handleWrite*(self: CodecElf,
                    ctx: Stream,
                    pre: string,
                    encoded: Option[string],
                    post: string) =
  ctx.write(pre)
  if encoded.isSome():
    ctx.write(encoded.get())

method getArtifactHash*(self: CodecElf, sami: SamiObj): string =
  var shaCtx = initSHA[SHA256]()
  let offset = sami.primary.startOffset

  sami.stream.setPosition(0)
  shaCtx.update(sami.stream.readStr(offset))

  return $shaCtx.final()

registerPlugin("elf", CodecElf())
