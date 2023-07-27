## Converts metadata keys into a canonical binary representation.
## Originally, this was used to inject into binaries, but we have
## moved that to JSON. This lives on though, to give us a way to
## normalize metadata for hashing and/or signing.  We don't use JSON
## for that, because it'd be too easy to lose interoperability if
## people whiff on whatever we decide for how to handle spaces, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import algorithm, config

proc u32ToStr(i: uint32): string =
  result = newStringOfCap(sizeof(uint32)+1)
  let arr = cast[array[4, char]](i)

  for ch in arr: result.add(ch)

proc u64ToStr(i: uint64): string =
  result = newStringOfCap(sizeof(uint64)+1)
  let arr = cast[array[8, char]](i)

  for ch in arr:
    result.add(ch)

proc binEncodeItem(self: Box): string
proc binEncodeStr(s: string): string =
  return "\x01" & u32ToStr(uint32(len(s))) & s
proc binEncodeInt(i: uint64): string =
  return "\x02" & u64ToStr(i)
proc binEncodeBool(b: bool): string  = return if b: "\x03\x01" else: "\x03\x00"

proc binEncodeArr(arr: seq[Box]): string =
  result = "\x04" & u32ToStr(uint32(len(arr)))

  for item in arr: result = result & binEncodeItem(item)

proc binEncodeObj(self: ChalkDict): string =
  result = "\x05" & u32ToStr(uint32(len(self)))

  for outputKey in self.keys():
    let val = self[outputKey]
    result  = result & binEncodeStr(outputKey) & binEncodeItem(val)

proc binEncodeItem(self: Box): string =
  case self.kind
  of MkBool:  return binEncodeBool(unpack[bool](self))
  of MkInt:   return binEncodeInt(unpack[uint64](self))
  of MkStr:   return binEncodeStr(unpack[string](self))
  of MkTable: return binEncodeObj(unpack[ChalkDict](self))
  of MkSeq:   return binEncodeArr(unpack[seq[Box]](self))
  else:       unreachable


proc getSortedKeys(d: ChalkDict): seq[string] {.inline.}=
  var k: seq[string] = @[]

  for item in d.keys():
    k.add(item)

  k.sort()
  return k

proc normalizeChalk*(dict: ChalkDict): string =
  # Currently, this is only called for the METADATA_HASH field, which only
  # signs things actually being written out.  We skip MAGIC, SIGNATURE
  # and SIGN_PARAMS.

  var fieldCount = 0
  let ignoreList = chalkConfig.getIgnoreWhenNormalizing()

  # Count how many fields we will write.
  for key, _ in dict:
    if key notin ignoreList: fieldCount = fieldCount + 1

  result = u32ToStr(uint32(fieldCount))

  for fullKey in dict.getSortedKeys():
    # It's important to write everything out in a canonical order for
    # signing.  The keys are written in the order we spec, and user-defined
    # keys are in lexigraphical order.
    #
    # Note that even dictionary values (e.g., SBOMS) are kept ordered by
    # the insertion ordering, so there is no ambiguity.
    var outputKey = fullKey

    if fullKey in ignoreList: continue
    let
      key = binEncodeStr(outputKey)
      val = binEncodeItem(dict[outputKey])
    result  &= key & val
