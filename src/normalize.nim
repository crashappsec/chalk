##
## Copyright (c) 2023, Crash Override, Inc.
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

import std/[algorithm, sequtils]
import "."/config

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

proc binEncodeItem*(self: Box): string

proc binEncodeStr(s: string): string =
  return "\x01" & u32ToStr(uint32(len(s))) & s

proc binEncodeInt(i: uint64): string =
  return "\x02" & u64ToStr(i)

proc binEncodeBool(b: bool): string  =
  return if b: "\x03\x01" else: "\x03\x00"

proc binEncodeArr(arr: seq[Box]): string =
  result = "\x04" & u32ToStr(uint32(len(arr)))
  for item in arr: result = result & binEncodeItem(item)

proc binEncodeTable(self: ChalkDict, ignore: seq[string] = @[]): string =
  var
    encoded = ""
    count   = 0
  # It's important to write everything out in a canonical order for
  # signing.  The keys are written in the order we spec, and user-defined
  # keys are in lexigraphical order.
  #
  # Note that even dictionary values (e.g., SBOMS) are kept ordered by
  # the insertion ordering, so there is no ambiguity.
  for k, v in self.sortedPairs():
    if k in ignore:
      continue
    encoded  &= binEncodeStr(k) & binEncodeItem(v)
    count += 1
  return "\x05" & u32ToStr(uint32(count)) & encoded

proc binEncodeFloat(f: float): string =
  result = "\x06" & floatToStr(f)

proc binEncodeObj(self: Box): string =
  if self.o == nil:
    return "\x07"
  else:
    error("non-null objects cannot be normalized")
    unreachable

proc binEncodeItem*(self: Box): string =
  case self.kind
  of MkBool:  return binEncodeBool(unpack[bool](self))
  of MkInt:   return binEncodeInt(unpack[uint64](self))
  of MkStr:   return binEncodeStr(unpack[string](self))
  of MkTable: return binEncodeTable(unpack[ChalkDict](self))
  of MkSeq:   return binEncodeArr(unpack[seq[Box]](self))
  of MkFloat: return binEncodeFloat(unpack[float](self))
  of MkObj:   return binEncodeObj(self)

proc normalizeChalk*(dict: ChalkDict): string =
  # Currently, this is only called for the METADATA_ID field, which only
  # signs things actually being written out.  We skip MAGIC, SIGNATURE
  # and SIGN_PARAMS.
  let ignoreList = attrGet[seq[string]]("ignore_when_normalizing")
  return binEncodeTable(dict, ignoreList)
