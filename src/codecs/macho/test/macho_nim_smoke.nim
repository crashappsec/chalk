## Standalone nim smoke test for src/utils/macho.nim FFI bindings.
##
## Build & run:
##   cd $CHALK_ROOT
##   SDKROOT=$(xcrun --show-sdk-path) nim c --cc:clang \
##     --passC:"-isysroot $SDKROOT" \
##     --path:src --path:$HOME/.nimble/pkgs2 -d:release \
##     src/codecs/macho/test/macho_nim_smoke.nim
##   ./src/codecs/macho/test/macho_nim_smoke /tmp/some-mach-o
##
## Confirms: parse, stripSignature, addChalkNote, getMutatedBytes
## round-trip, the unchalked-hash invariant, and removeChalkNote.

import std/[os, strformat]
import "../../../utils"/macho

proc main() =
  if paramCount() != 1:
    quit("usage: macho_nim_smoke <path>", 2)

  let
    path  = paramStr(1)
    bytes = readFile(path)

  var parsed = parseMacho(bytes)
  if parsed == nil:
    quit(&"parse failed for {path}")

  let baseline = parsed.unchalkedHash()
  echo &"baseline unchalked hash: {baseline}"

  # The codec layer (codecMacho.nim) calls stripSignature before
  # addChalkNote.  Replicate that here.
  let stripSt = parsed.stripSignature()
  if stripSt != cmOk:
    quit(&"stripSignature failed: {stripSt}")

  let payload = "{\"chalk\":\"nim test\"}"
  let st = parsed.addChalkNote(payload)
  if st != cmOk:
    quit(&"addChalkNote failed: {st}")

  let marked = parsed.getMutatedBytes()
  echo &"after addChalkNote: {marked.len} bytes"

  # Reparse the marked bytes and verify the hash invariant + payload.
  var reparsed = parseMacho(marked)
  if reparsed == nil:
    quit("reparse of marked bytes failed")

  let markedHash = reparsed.unchalkedHash()
  echo &"marked unchalked hash:   {markedHash}"
  if markedHash != baseline:
    quit("unchalked hash drifted across mark")

  let recovered = reparsed.getChalkPayload()
  echo &"recovered payload: {recovered.len} bytes: {recovered}"
  if recovered != payload:
    quit("recovered payload mismatch")

  let st2 = reparsed.removeChalkNote()
  if st2 != cmOk:
    quit(&"removeChalkNote failed: {st2}")

  let stripped = reparsed.getMutatedBytes()
  echo &"after removeChalkNote: {stripped.len} bytes"

  var rereparsed = parseMacho(stripped)
  if rereparsed == nil:
    quit("reparse after remove failed")

  if rereparsed.getChalkPayload() != "":
    quit("chalk payload still present after remove")

  echo "ok"

main()
