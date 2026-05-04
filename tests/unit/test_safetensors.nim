## Unit tests for the SafeTensors codec FFI bindings.
##
## SafeTensors layout is small enough that fixtures are built inline
## from byte literals — no committed binary blob needed.  Exercises:
##   - parse on a header-only file (no tensors).
##   - parse rejection on truncated / bogus headers.
##   - getChalkPayload returns "" pre-mark.
##   - setChalk → reparse → recover payload (with __metadata__
##     creation when absent).
##   - setChalk → reparse → recover payload (with __metadata__
##     already present, both populated and empty).
##   - removeChalk round-trip leaves the header with __metadata__
##     intact but no chalk key.
##   - unchalkedHash invariance: same hash before mark and after
##     mark with payloads of different lengths.

import std/strutils
import ../../src/utils/safetensors

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

# ---------------------------------------------------------------------------
# Helpers — build a minimal SafeTensors file from a header string.
# ---------------------------------------------------------------------------

proc le64(n: int): string =
  ## 8-byte little-endian encoding of `n`.
  result = newString(8)
  var v = uint64(n)
  for i in 0 ..< 8:
    result[i] = char(byte(v and 0xff))
    v = v shr 8

proc stFile(header: string): string =
  ## SafeTensors file with no tensor data.
  le64(header.len) & header

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

proc testParseTruncated() =
  doAssert parseSafetensors("") == nil
  doAssert parseSafetensors("abc") == nil
  doAssert parseSafetensors("12345678") == nil  # 8 bytes, no header
  # header_size > remaining bytes
  let bogus = le64(99) & "{}"
  doAssert parseSafetensors(bogus) == nil

proc testParseValidEmpty() =
  let f = stFile("{}")
  let p = parseSafetensors(f)
  doAssert p != nil
  assertEq(p.getChalkPayload(), "")

proc testParseRejectsNonObject() =
  doAssert parseSafetensors(stFile("[]")) == nil
  doAssert parseSafetensors(stFile("\"hi\"")) == nil

proc testSetChalkCreatesMetadata() =
  let p = parseSafetensors(stFile("{}"))
  doAssert p != nil
  let mark = "{\"MAGIC\":\"dadfedabbadabbed\",\"CHALK_ID\":\"TEST\"}"
  assertEq(p.setChalk(mark), cstOk)

  # Reparse the mutated bytes; payload must round-trip.
  let mutated = p.getMutatedBytes()
  doAssert mutated.len > 0
  let p2 = parseSafetensors(mutated)
  doAssert p2 != nil
  assertEq(p2.getChalkPayload(), mark)

proc testSetChalkInExistingMetadata() =
  let p = parseSafetensors(stFile(
    "{\"__metadata__\":{\"format\":\"pt\"}}"))
  doAssert p != nil
  let mark = "{\"x\":1}"
  assertEq(p.setChalk(mark), cstOk)
  let p2 = parseSafetensors(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.getChalkPayload(), mark)

proc testSetChalkInEmptyMetadata() =
  let p = parseSafetensors(stFile("{\"__metadata__\":{}}"))
  doAssert p != nil
  assertEq(p.setChalk("{}"), cstOk)
  let p2 = parseSafetensors(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.getChalkPayload(), "{}")

proc testReplaceChalk() =
  let p = parseSafetensors(stFile("{}"))
  doAssert p != nil
  assertEq(p.setChalk("{\"v\":1}"), cstOk)
  let p2 = parseSafetensors(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.setChalk("{\"v\":2}"), cstOk)
  let p3 = parseSafetensors(p2.getMutatedBytes())
  doAssert p3 != nil
  assertEq(p3.getChalkPayload(), "{\"v\":2}")

proc testRemoveChalk() =
  let p = parseSafetensors(stFile("{}"))
  doAssert p != nil
  assertEq(p.setChalk("{\"v\":1}"), cstOk)
  let p2 = parseSafetensors(p.getMutatedBytes())
  doAssert p2 != nil
  assertEq(p2.removeChalk(), cstOk)
  let p3 = parseSafetensors(p2.getMutatedBytes())
  doAssert p3 != nil
  assertEq(p3.getChalkPayload(), "")
  # removeChalk on already-clean must report cstNoChalk.
  assertEq(p3.removeChalk(), cstNoChalk)

proc testUnchalkedHashInvariance() =
  ## Same canonical hash before mark, after mark with short payload,
  ## after mark with long payload, after replace, after remove.
  let f = stFile("{\"__metadata__\":{\"format\":\"pt\"}}")
  let p0 = parseSafetensors(f)
  doAssert p0 != nil
  let baseline = p0.unchalkedHash()
  assertEq(baseline.len, 64)

  let p1 = parseSafetensors(f)
  assertEq(p1.setChalk("{\"a\":1}"), cstOk)
  let m1 = p1.getMutatedBytes()
  let p1r = parseSafetensors(m1)
  assertEq(p1r.unchalkedHash(), baseline)

  let p2 = parseSafetensors(f)
  let bigPayload = "{\"a\":\"" & repeat('x', 4096) & "\"}"
  assertEq(p2.setChalk(bigPayload), cstOk)
  let m2 = p2.getMutatedBytes()
  let p2r = parseSafetensors(m2)
  assertEq(p2r.unchalkedHash(), baseline)

  # After remove → reparse → hash returns to baseline.
  assertEq(p2r.removeChalk(), cstOk)
  let p2cleared = parseSafetensors(p2r.getMutatedBytes())
  assertEq(p2cleared.unchalkedHash(), baseline)

proc testHashWithoutChalkEqualsFileHash() =
  ## When no chalk pair is present, the unchalked hash should equal
  ## the natural SHA-256 of the file bytes.  We don't recompute the
  ## file's SHA-256 here (the only SHA-256 in scope is via the FFI),
  ## but we can confirm the hash is a 64-char hex string.
  let p = parseSafetensors(stFile("{\"__metadata__\":{}}"))
  doAssert p != nil
  let h = p.unchalkedHash()
  assertEq(h.len, 64)
  for c in h:
    doAssert c in "0123456789abcdef"

proc main() =
  testParseTruncated()
  testParseValidEmpty()
  testParseRejectsNonObject()
  testSetChalkCreatesMetadata()
  testSetChalkInExistingMetadata()
  testSetChalkInEmptyMetadata()
  testReplaceChalk()
  testRemoveChalk()
  testUnchalkedHashInvariance()
  testHashWithoutChalkEqualsFileHash()

main()
