import ../resources
import ../types
import nimutils/box

import endians
import streams
import tables

proc itemFromBin(stream: FileStream, swapEndian: bool): Box

proc handleEndian(n: var uint32, swap: bool): uint32 {.inline.} =
  if not swap: return n

  var res: uint32
  swapEndian32(addr(res), addr(n))

  return res

proc handleEndian(n: var uint64, swap: bool): uint64 {.inline.} =
  if not swap: return n

  var res: uint64
  swapEndian64(addr(res), addr(n))

  return res

proc strFromBin(stream: FileStream, swapEndian: bool): string =
  var n = stream.readUint32()

  n = n.handleEndian(swapEndian)

  result = stream.readStr(int(n))

  if len(result) != int(n):
    raise newException(IOError, eStrParse)

proc intFromBin(stream: FileStream, swapEndian: bool): uint64 =
  var n = stream.readUint64()

  return n.handleEndian(swapEndian)

proc arrFromBin(stream: FileStream, swapEndian: bool): seq[Box] =
  result = newSeq[Box]()

  var n = stream.readUint32()

  n = n.handleEndian(swapEndian)

  for i in 1 .. n:
    result.add(stream.itemFromBin(swapEndian))

proc objFromBin(stream: FileStream, swapEndian: bool): SamiDict =
  result = new(SamiDict)

  assert stream != nil
  echo stream.getPosition()
  var n = stream.readUint32()

  n = n.handleEndian(swapEndian)

  for i in 1 .. n:
    let typecode = stream.readUint8()

    if typecode != binTypeString:
      raise newException(IOError, eBinParse)

    let
      k: string = stream.strFromBin(swapEndian)
      v: Box = stream.itemFromBin(swapEndian)
    result[k] = v

proc itemFromBin(stream: FileStream, swapEndian: bool): Box =
  let valcode: uint8 = stream.readUint8()

  case valcode
  of binTypeNull: return
  of binTypeString: return pack(stream.strFromBin(swapEndian))
  of binTypeInteger: return pack(stream.intFromBin(swapEndian))
  of binTypeBool:
    case stream.readUint8()
    of 0: return pack(false)
    of 1: return pack(true)
    else:
      raise newException(IOError, eBoolParse)
  of binTypeArray:
    let
      a = stream.arrFromBin(swapEndian)
      b = pack(a)
    return b
  of binTypeObj:
    let
      o = stream.objFromBin(swapEndian)
      b = pack(o)
    return b

  else: raise newException(IOError, eUnkObjT)

proc extractOneSamiBinary*(sami: SamiObj, swapEndian: bool): SamiDict =
  return sami.stream.objFromBin(swapEndian)

