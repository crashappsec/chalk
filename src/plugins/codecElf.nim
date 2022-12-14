import ../types
import ../resources
import ../plugins
import ../config

import nimsha2

import endians
import streams
import strutils
import strformat

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

const b64OffsetLoc = 0x28
#const b32OffsetLoc = 0x20
const wsOffsetLoc = 0x04
const is64BitVal = char(0x02)
const bigEndianVal = char(0x02)

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
  var shStart: uint64
  var present: bool
  var offset: int

  sami.flags.incl(Binary)

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
      offset1 = secHdr.find(magicBin)
      offset2 = secHdr.find(magicSwapped)

    #let total = len(secHdr) + int(shStart)

    if offset1 != -1:
      offset = int(shStart) + offset1
      present = true
    elif offset2 != -1:
      offset = int(shStart) + offset2
      present = true
    else:
      offset = int(shStart) + secHdr.len()
      present = false

  sami.primary = SamiPoint(startOffset: offset, present: present)

  return true

method scan*(self: CodecElf, sami: SamiObj): bool =
  if sami.stream == nil:
    warn(fmt"could not open {sami.fullpath}")
    return
  try:
    sami.stream.setPosition(0)
    let magic = sami.stream.readUint32()

    if magic != elfMagic and magic != elfSwapped:
      return false
  except:
    return false

  return self.extractKeyMetadata(sami)

method handleWrite*(self: CodecElf,
                    ctx: Stream,
                    pre: string,
                    encoded: string,
                    post: string) =
  ctx.write(pre)
  ctx.write(encoded)

method getArtifactHash*(self: CodecElf, sami: SamiObj): string =
  var shaCtx = initSHA[SHA256]()
  let offset = sami.primary.startOffset

  sami.stream.setPosition(0)
  shaCtx.update(sami.stream.readStr(offset))

  return $shaCtx.final()

registerPlugin("elf", CodecElf())
