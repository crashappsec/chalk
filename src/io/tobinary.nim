## Converts metadata keys into a canonical binary representation.
## Originally, this was used to inject into binaries, but we have
## moved that to JSON. This lives on though, to give us a way to
## normalize metadata for hashing and/or signing.  We don't use JSON
## for that, because it'd be too easy to lose interoperability if
## people whiff on whatever we decide for how to handle spaces, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strformat, strutils, nimutils, ../types, ../config

const
  kvPairBinFmt   = "{result}{binEncodeStr(outputkey)}{binEncodeItem(val)}"
  binStrItemFmt  = "\x01{u32ToStr(uint32(len(s)))}{s}"
  binIntItemFmt  = "\x02{u64ToStr(uint64(i))}"
  binTrue        = "\x03\x01"
  binFalse       = "\x03\x00"
  binArrStartFmt = "\x04{u32ToStr(uint32(len(arr)))}"
  binObjHdr      = "\x05{u32ToStr(uint32(len(self)))}"
  skipList       = ["_MAGIC", "METADATA_HASH", "METADATA_ID",
                    "SIGN_PARAMS", "SIGNATURE"]



proc u32ToStr*(i: uint32): string =
  result = newStringOfCap(sizeof(uint32)+1)
  let arr = cast[array[4, char]](i)

  for ch in arr:
    result.add(ch)

proc u64ToStr*(i: uint64): string =
  result = newStringOfCap(sizeof(uint64)+1)
  let arr = cast[array[8, char]](i)

  for ch in arr:
    result.add(ch)

proc binEncodeItem(self: Box): string

proc binEncodeStr(s: string): string

proc binEncodeStr(s: string): string =
  return binStrItemFmt.fmt()

proc binEncodeInt(i: uint64): string =
  return binIntItemFmt.fmt()

proc binEncodeBool(b: bool): string =
  if b: return binTrue
  else: return binFalse

proc binEncodeArr(arr: seq[Box]): string =
  result = binArrStartFmt.fmt()

  for item in arr:
    result = result & binEncodeItem(item)

proc binEncodeObj(self: ChalkDict): string =
  result = binObjHdr.fmt()

  for outputKey in self.keys():
    let val = self[outputKey]
    result = kvPairBinFmt.fmt()

proc binEncodeItem(self: Box): string =
  case self.kind
  of MkBool: return binEncodeBool(unpack[bool](self))
  of MkInt: return binEncodeInt(unpack[uint64](self))
  of MkStr:
    return binEncodeStr(unpack[string](self))
  of MkTable:
    return binEncodeObj(unpack[ChalkDict](self))
  of MkSeq:
    return binEncodeArr(unpack[seq[Box]](self))
  else:
    unreachable

proc createdToBinary*(obj: ChalkObj, ptrOnly = getOutputPointers()): string =
  # Currently, this is only called for the METADATA_HASH field, which only
  # signs things actually being written out.  We skip everything else.
  var fieldCount = 0

  # Count how many fields we will write.
  for key, _ in obj.newFields:
    if key.startsWith("_"):
      continue
    let spec = getKeySpec(key).get()
    if spec.getSkip():
      continue
    if ptrOnly and not spec.getInPtr():
      continue

    fieldCount += 1

  result = u32ToStr(uint32(fieldCount))

  for fullKey in getOrderedKeys():
    # It's important to write everything out in a canonical order for
    # signing.  The keys are written in the order we spec, and user-defined
    # keys are in lexigraphical order.
    #
    # Note that even dictionary values (e.g., SBOMS) are kept ordered by
    # the insertion ordering, so there is no ambiguity.
    var outputKey = fullKey

    if fullKey.startsWith("_"):
      continue

    # If this key is set, but ptrOnly is false, then we are
    # outputting the "full" chalk, in which case we do not
    # write this field out.
    if outputKey == "CHALK_PTR" and not ptrOnly:
      continue

    let spec = getKeySpec(fullKey).get()

    if not obj.newFields.contains(fullKey):
      continue

    # Skip outputting this key if "skip" is set in the key's existing
    # configuration.
    if spec.getSkip():
      continue

    # If chalk pointers are set up, and we're currently outputting
    # a pointer, then we only output if the config has the in_ptr
    # field set.
    if ptrOnly and not spec.getInPtr():
      continue

    let val = obj.newFields[outputKey]
    result = kvPairBinFmt.fmt()

proc foundToBinary*(kvPairs: ChalkDict): string =
  var keys: seq[string]

  for k, v in kvPairs:
    if k in skipList: continue
    keys.add(k)

  keys = orderKeys(keys)

  result = u32ToStr(uint32(len(keys)))

  for outputkey in keys:
    let val = kvPairs[outputKey]
    result = kvPairBinFmt.fmt()
