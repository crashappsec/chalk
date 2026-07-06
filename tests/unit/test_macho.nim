## Unit tests for the native Mach-O codec FFI bindings.
##
## Exercises:
##   - parseMacho on a real arm64 Mach-O fixture.
##   - signatureKind classification.
##   - stripSignature → addChalkNote → reparse → recover payload.
##   - unchalkedHash invariance across mark / unmark.
##   - removeChalkNote round-trip.
##   - lcSlack() reports < 40 for a binary with tight LC header padding
##     (macho_arm64_no_lc_slack.bin), confirming it would be deferred to
##     the script wrapper codec instead of being marked natively.
##
## Fixtures (tests/unit/fixtures/):
##   macho_arm64_adhoc.bin       — tiny clang hello, ad-hoc-signed, with
##                                  headerpad room for LC_NOTE insertion.
##   macho_arm64_no_lc_slack.bin — same binary with sizeofcmds bumped so
##                                  LC header slack == 32 B (< 40 threshold);
##                                  the native codec must defer to the wrapper.
##
## Both committed so Linux CI runners have something to test against.

import ../../src/utils/macho

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const fixtureBytes        = staticRead("fixtures/macho_arm64_adhoc.bin")
const noSlackFixtureBytes = staticRead("fixtures/macho_arm64_no_lc_slack.bin")

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

  # ---- no-lc-slack fixture: parse + slack check ----
  # macho_arm64_no_lc_slack.bin has sizeofcmds patched up by 64 bytes so
  # that only 32 bytes of LC header slack remain.  The native codec guard
  # (codecMacho.nim) checks lcSlack() < 40 and defers to the script wrapper
  # rather than attempting (and silently corrupting) a native mark.
  let noSlackParsed = parseMacho(noSlackFixtureBytes)
  doAssert noSlackParsed != nil, "parseMacho failed on no-lc-slack fixture"
  let slack = noSlackParsed.lcSlack()
  doAssert slack < 40, "expected lcSlack < 40, got " & $slack
  doAssert noSlackParsed.signatureKind() == csAdhoc, "expected csAdhoc"

main()
