import tables, options, strformat, strutils, nimutils, ../config

const
  kvPairBinFmt   = "{result}{binEncodeStr(outputkey)}{binEncodeItem(val)}"
  binStrItemFmt  = "\x01{u32ToStr(uint32(len(s)))}{s}"
  binIntItemFmt  = "\x02{u64ToStr(uint64(i))}"
  binTrue        = "\x03\x01"
  binFalse       = "\x03\x00"
  binArrStartFmt = "\x05{u32ToStr(uint32(len(arr)))}"
  binObjHdr      = "\x06{u32ToStr(uint32(len(self)))}"


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

proc binEncodeObj(self: SamiDict): string =
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
    return binEncodeObj(unpack[SamiDict](self))
  of MkSeq:
    return binEncodeArr(unpack[seq[Box]](self))
  else:
    unreachable

proc createdToBinary*(sami: SamiObj, ptrOnly = getOutputPointers()): string =
  # Currently, this is only called for the METADATA_HASH field, which only
  # signs things actually being written out.  We skip everything else.
  var fieldCount = 0

  # Count how many fields we will write.  Ignore .json fields
  for key, _ in sami.newFields:
    if "." in key:
      let parts = key.split(".")
      if len(parts) != 2 or parts[1] != "binary":
        continue
    let spec = getKeySpec(key).get()
    if spec.getSkip():
      continue
    if ptrOnly and not spec.getInPtr():
      continue

    fieldCount += 1

  result = magicBin & u32ToStr(uint32(fieldCount))

  for fullKey in getOrderedKeys():
    # It's important to write everything out in a canonical order for
    # signing.  The keys are written in the order we spec, and user-defined
    # keys are in lexigraphical order.
    #
    # Note that even dictionary values (e.g., SBOMS) are kept ordered by
    # the insertion ordering, so there is no ambiguity.
    var outputKey = fullKey

    if "." in fullKey:
      let parts = fullKey.split(".")
      if len(parts) != 2 or parts[1] != "binary":
        continue
      outputKey = parts[0]

    # If this key is set, but ptrOnly is false, then we are
    # outputting the "full" SAMI, in which case we do not
    # write this field out.
    if outputKey == "SAMI_PTR" and not ptrOnly:
      continue

    let spec = getKeySpec(fullKey).get()

    if not sami.newFields.contains(fullKey):
      continue

    # Skip outputting this key if "skip" is set in the key's existing
    # configuration.
    if spec.getSkip():
      continue

    # If SAMI pointers are set up, and we're currently outputting
    # a pointer, then we only output if the config has the in_ptr
    # field set.
    if ptrOnly and not spec.getInPtr():
      continue

    let val = sami.newFields[outputKey]
    result = kvPairBinFmt.fmt()
