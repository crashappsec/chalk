## Unit tests for the GGUF codec FFI bindings.
##
## GGUF fixtures are built inline from byte literals — the format is
## small enough that no committed binary blob is needed.  Exercises:
##   - parse on a header-only file (no tensors).
##   - parse rejection on bad magic / wrong version / truncation.
##   - getChalkPayload returns "" pre-mark.
##   - setChalk → reparse → recover payload.
##   - replace existing chalk.mark KV with a new payload.
##   - removeChalk round-trip leaves the file with kv_count
##     decremented and chalk.mark gone.
##   - unchalkedHash invariance: same hash before mark and after
##     mark with payloads of different lengths, before and after
##     replace, before and after remove.
##   - alignment-padding recompute: data section start moves to the
##     correct aligned offset after KV section size changes.

import std/strutils
import ../../src/utils/gguf

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

# ---------------------------------------------------------------------------
# Helpers — build a minimal GGUF file from primitives.
# ---------------------------------------------------------------------------

proc le32(n: int): string =
  result = newString(4)
  var v = uint32(n)
  for i in 0 ..< 4:
    result[i] = char(byte(v and 0xff'u32))
    v = v shr 8

proc le64(n: int): string =
  result = newString(8)
  var v = uint64(n)
  for i in 0 ..< 8:
    result[i] = char(byte(v and 0xff'u64))
    v = v shr 8

proc kvString(key, value: string): string =
  ## A string-typed GGUF KV pair.
  result = le64(key.len) & key & le32(8) & le64(value.len) & value

proc kvUint32(key: string, value: uint32): string =
  ## A uint32-typed GGUF KV pair.
  result = le64(key.len) & key & le32(4) & le32(int(value))

proc fromBytesLE(t: typedesc[uint32], s: string, off: int): uint32 =
  result = 0
  for i in 0 ..< 4:
    result = result or (uint32(byte(s[off + i])) shl (i * 8))

proc fromBytesLE(t: typedesc[uint64], s: string, off: int): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = result or (uint64(byte(s[off + i])) shl (i * 8))

proc countKv(kvs: string): int =
  ## Count well-formed string-or-uint32 KV pairs in a buffer built by
  ## kvString/kvUint32.  Used by ggufFile to fill in kv_count.
  var pos = 0
  result  = 0
  while pos < kvs.len:
    if pos + 8 > kvs.len: return result
    let kl = uint64.fromBytesLE(kvs, pos)
    pos += 8 + int(kl)
    if pos + 4 > kvs.len: return result
    let vt = uint32.fromBytesLE(kvs, pos)
    pos += 4
    case vt
    of 4'u32: pos += 4              # uint32
    of 8'u32:                       # string
      if pos + 8 > kvs.len: return result
      let vl = uint64.fromBytesLE(kvs, pos)
      pos += 8 + int(vl)
    else:
      return result
    inc result

proc ggufFile(version: int,
              tensorCount: int,
              kvs: string,
              alignment: int = 32): string =
  ## Build a GGUF file with no tensors and the supplied KV section.
  ## Pads the file from end-of-KV up to a multiple of `alignment`,
  ## then appends no tensor data.  Even with zero tensors this is a
  ## valid GGUF — readers stop after kv_count pairs.
  let kvCount = countKv(kvs)
  let header  = "GGUF" & le32(version) & le64(tensorCount) & le64(kvCount)
  var s       = header & kvs
  let pad     = (alignment - (s.len mod alignment)) mod alignment
  s.add(repeat('\0', pad))
  result = s

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

proc testParseRejections() =
  doAssert parseGguf("") == nil
  doAssert parseGguf("FOO!") == nil          # bad magic
  doAssert parseGguf("12345678901234567890") == nil  # too short
  # Valid magic, bad version (1)
  let badV = "GGUF" & le32(1) & le64(0) & le64(0)
  doAssert parseGguf(badV) == nil

proc testParseEmpty() =
  let f = ggufFile(version = 3, tensorCount = 0, kvs = "")
  let p = parseGguf(f)
  doAssert p != nil
  assertEq(p.getChalkPayload(), "")

proc testSetChalkOnEmpty() =
  let f = ggufFile(version = 3, tensorCount = 0, kvs = "")
  let p = parseGguf(f)
  doAssert p != nil
  let mark = "{\"MAGIC\":\"dadfedabbadabbed\",\"CHALK_ID\":\"TEST\"}"
  assertEq(p.setChalk(mark), cgOk)
  let p2 = parseGguf(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.getChalkPayload(), mark)

proc testSetChalkWithExistingKvs() =
  let kvs = kvString("general.architecture", "llama") &
            kvUint32("general.alignment", 32'u32)
  let f   = ggufFile(version = 3, tensorCount = 0, kvs = kvs)
  let p   = parseGguf(f)
  doAssert p != nil
  let mark = "{\"x\":1}"
  assertEq(p.setChalk(mark), cgOk)
  let p2 = parseGguf(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.getChalkPayload(), mark)

proc testReplaceChalk() =
  let f = ggufFile(version = 3, tensorCount = 0, kvs = "")
  let p = parseGguf(f)
  doAssert p != nil
  assertEq(p.setChalk("{\"v\":1}"), cgOk)
  let p2 = parseGguf(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.setChalk("{\"v\":2}"), cgOk)
  let p3 = parseGguf(p2.getMutatedBytes())
  doAssert p3 != nil
  assertEq(p3.getChalkPayload(), "{\"v\":2}")

proc testRemoveChalk() =
  let f = ggufFile(version = 3, tensorCount = 0, kvs = "")
  let p = parseGguf(f)
  doAssert p != nil
  assertEq(p.setChalk("{\"v\":1}"), cgOk)
  let p2 = parseGguf(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.removeChalk(), cgOk)
  let p3 = parseGguf(p2.getMutatedBytes())
  doAssert p3 != nil
  assertEq(p3.getChalkPayload(), "")
  assertEq(p3.removeChalk(), cgNoChalk)

proc testUnchalkedHashInvariance() =
  ## Same canonical hash before mark, after mark with various
  ## payload lengths, after replace, after remove.
  let kvs = kvString("general.architecture", "llama")
  let f   = ggufFile(version = 3, tensorCount = 0, kvs = kvs)
  let p0  = parseGguf(f)
  doAssert p0 != nil
  let baseline = p0.unchalkedHash()
  assertEq(baseline.len, 64)

  let p1 = parseGguf(f)
  assertEq(p1.setChalk("{\"a\":1}"), cgOk)
  let p1r = parseGguf(p1.getMutatedBytes())
  assertEq(p1r.unchalkedHash(), baseline)

  let p2 = parseGguf(f)
  let big = "{\"a\":\"" & repeat('x', 4096) & "\"}"
  assertEq(p2.setChalk(big), cgOk)
  let p2r = parseGguf(p2.getMutatedBytes())
  assertEq(p2r.unchalkedHash(), baseline)

  assertEq(p2r.removeChalk(), cgOk)
  let p2cleared = parseGguf(p2r.getMutatedBytes())
  assertEq(p2cleared.unchalkedHash(), baseline)

proc testAlignmentRecompute() =
  ## After insert/remove, the data section start must land on a
  ## multiple of `general.alignment`.  We don't have direct access
  ## to data_off from the wrapper, but we can assert that the file
  ## length matches a layout where the data section is aligned
  ## (since this fixture has zero tensors, that's just the end).
  let kvs = kvUint32("general.alignment", 64'u32)
  let f   = ggufFile(version = 3, tensorCount = 0, kvs = kvs,
                     alignment = 64)
  let p   = parseGguf(f)
  doAssert p != nil
  assertEq(p.setChalk("{\"a\":1}"), cgOk)
  let m = p.getMutatedBytes()
  doAssert (m.len mod 64) == 0,
    "post-set length " & $m.len & " not aligned to 64"

  let p2 = parseGguf(m)
  doAssert p2 != nil
  assertEq(p2.removeChalk(), cgOk)
  let m2 = p2.getMutatedBytes()
  doAssert (m2.len mod 64) == 0,
    "post-remove length " & $m2.len & " not aligned to 64"

proc main() =
  testParseRejections()
  testParseEmpty()
  testSetChalkOnEmpty()
  testSetChalkWithExistingKvs()
  testReplaceChalk()
  testRemoveChalk()
  testUnchalkedHashInvariance()
  testAlignmentRecompute()

main()
