## Unit tests for the native Mach-O codec FFI bindings.
##
## Exercises:
##   - parseMacho on a real arm64 Mach-O fixture.
##   - signatureKind classification.
##   - stripSignature → addChalkNote → reparse → recover payload.
##   - unchalkedHash invariance across mark / unmark.
##   - removeChalkNote round-trip.
##
## Fixture: tests/unit/fixtures/macho_arm64_adhoc.bin — a tiny
## clang-compiled "hello" binary, ad-hoc-signed by the linker, with
## headerpad room for LC_NOTE insertion.  Committed so Linux CI
## runners have something to test against.

import ../../src/utils/macho

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const fixtureBytes = staticRead("fixtures/macho_arm64_adhoc.bin")

proc isMagic(s: string): bool =
  var arr: array[4, char]
  for i in 0 ..< min(4, s.len):
    arr[i] = s[i]
  isMachoMagic(arr)

proc main() =
  # ---- parse ----
  let parsed = parseMacho(fixtureBytes)
  doAssert parsed != nil, "parseMacho failed on fixture"

  # ---- magic detection ----
  doAssert isMagic(fixtureBytes[0 .. 3])
  doAssert not isMagic("\x7FELF")    # ELF, not Mach-O
  doAssert not isMagic("foo")        # too short

  # ---- signature classification ----
  # The clang linker auto-applies an ad-hoc signature on arm64,
  # so the fixture should classify as csAdhoc.
  let sig = parsed.signatureKind()
  doAssert sig == csAdhoc, "expected csAdhoc, got " & $sig

  # ---- baseline unchalked hash ----
  let baseline = parsed.unchalkedHash()
  assertEq(baseline.len, 64)

  # ---- strip + addChalkNote ----
  assertEq(parsed.stripSignature(), cmOk)

  const payload = "{\"chalk\":\"unit-test\"}"
  assertEq(parsed.addChalkNote(payload), cmOk)

  let marked = parsed.getMutatedBytes()
  doAssert marked.len > 0
  # Note: marked.len may be smaller than fixtureBytes.len because
  # stripSignature dropped the linker-applied ad-hoc sig blob (a few
  # hundred bytes) before we added our 40-byte LC_NOTE + small
  # payload.  A subsequent codesign --force --sign - on disk would
  # reinflate it past original size.

  # ---- reparse marked bytes ----
  let reparsed = parseMacho(marked)
  doAssert reparsed != nil, "reparse of marked bytes failed"

  # ---- recover payload ----
  assertEq(reparsed.getChalkPayload(), payload)

  # ---- hash invariance ----
  assertEq(reparsed.unchalkedHash(), baseline)

  # ---- remove + reparse + confirm gone ----
  assertEq(reparsed.removeChalkNote(), cmOk)
  let stripped = reparsed.getMutatedBytes()
  let rereparsed = parseMacho(stripped)
  doAssert rereparsed != nil
  assertEq(rereparsed.getChalkPayload(), "")

main()
