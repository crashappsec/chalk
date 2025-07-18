##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Converts metadata keys into a canonical binary representation.
## Originally, this was used to inject into binaries, but we have
## moved that to JSON. This lives on though, to give us a way to
## normalize metadata for hashing and/or signing.  We don't use JSON
## for that, because it'd be too easy to lose interoperability if
## people whiff on whatever we decide for how to handle spaces, etc.

import std/[
  algorithm,
  sequtils,
  streams,
]
import "."/[
  types,
]

iterator sortedPairs(d: ChalkDict): tuple[key: string, value: Box] =
  for key in d.keys().toSeq().sorted():
    yield (key, d[key])

proc u32ToStr(i: uint32): string =
  result = newStringOfCap(sizeof(uint32)+1)
  let arr = cast[array[4, char]](i)

  for ch in arr: result.add(ch)

proc u64ToStr(i: uint64): string =
  result = newStringOfCap(sizeof(uint64)+1)
  let arr = cast[array[8, char]](i)

  for ch in arr:
    result.add(ch)

proc floatToStr(f: float): string =
  result = newStringOfCap(sizeof(float)+1)

proc binEncodeItem(s: Stream, self: Box)

proc binEncodeStr(t: Stream, s: string) =
  t.write("\x01")
  t.write(u32ToStr(uint32(len(s))))
  t.write(s)

proc binEncodeInt(s: Stream, i: uint64) =
  s.write("\x02")
  s.write(u64ToStr(i))

proc binEncodeBool(s: Stream, b: bool) =
  if b:
    s.write("\x03\x01")
  else:
    s.write("\x03\x00")

proc binEncodeArr(s: Stream, arr: seq[Box]) =
  s.write("\x04")
  s.write(u32ToStr(uint32(len(arr))))
  for item in arr:
    s.binEncodeItem(item)

proc binEncodeTable(s: Stream, self: ChalkDict, ignore: seq[string] = @[]) =
  # we dont know the count ahead of time as we need to account for ignores
  # so we can write 0 for now and then replace the stream content with updated count
  var count = 0
  s.write("\x05")
  let countPosition = s.getPosition()
  s.write(u32ToStr(uint32(count)))
  # It's important to write everything out in a canonical order for
  # signing.  The keys are written in the order we spec, and user-defined
  # keys are in lexigraphical order.
  #
  # Note that even dictionary values (e.g., SBOMS) are kept ordered by
  # the insertion ordering, so there is no ambiguity.
  for k, v in self.sortedPairs():
    if k in ignore:
      continue
    s.binEncodeStr(k)
    s.binEncodeItem(v)
    count += 1
  let endPosition = s.getPosition()
  s.setPosition(countPosition)
  # replace the count in the stream
  s.write(u32ToStr(uint32(count)))
  s.setPosition(endPosition)

proc binEncodeFloat(s: Stream, f: float) =
  s.write("\X06")
  s.write(floatToStr(f))

proc binEncodeObj(s: Stream, self: Box) =
  if self.o == nil:
    s.write("\x07")
  else:
    error("non-null objects cannot be normalized")
    unreachable

proc binEncodeItem(s: Stream, self: Box) =
  case self.kind
  of MkBool:  s.binEncodeBool(unpack[bool](self))
  of MkInt:   s.binEncodeInt(unpack[uint64](self))
  of MkStr:   s.binEncodeStr(unpack[string](self))
  of MkTable: s.binEncodeTable(unpack[ChalkDict](self))
  of MkSeq:   s.binEncodeArr(unpack[seq[Box]](self))
  of MkFloat: s.binEncodeFloat(unpack[float](self))
  of MkObj:   s.binEncodeObj(self)

proc binEncodeItem*(self: Box): string =
  let s = newStringStream()
  s.binEncodeItem(self)
  s.setPosition(0)
  result = s.readAll()

proc normalizeChalk*(dict: ChalkDict): string =
  # Currently, this is only called for the METADATA_ID field, which only
  # signs things actually being written out.  We skip MAGIC, SIGNATURE
  # and SIGN_PARAMS.
  let
    ignoreList = attrGet[seq[string]]("ignore_when_normalizing")
    s          = newStringStream()
  s.binEncodeTable(dict, ignoreList)
  s.setPosition(0)
  result = s.readAll()
