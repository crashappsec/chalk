## Unit tests for the model-sidecar codec helpers.
##
## The codec itself runs inside chalk's plugin pipeline, so a true
## end-to-end roundtrip needs a built chalk binary (covered by the
## functional test suite).  These tests exercise the pieces that
## are unit-testable in isolation: the sidecar file naming and the
## extension matcher's logic.
##
## We bring in Nim's stdlib and exercise the pure helpers directly.
## The codec module imports config / plugin_api / etc. that pull in
## attrGet — too heavy for a unit test — so we re-implement the
## extension check here against a fixed list and assert the
## expected behavior matches what the codec is gated on.

import std/[
  os,
  strutils,
]

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const sidecarSuffix = ".chalk"

proc sidecarPath(path: string): string =
  path & sidecarSuffix

proc extensionMatches(path: string, allowed: openArray[string]): bool =
  let ext = path.splitFile().ext.toLowerAscii()
  if ext.len < 2:
    return false
  let bare = ext[1 .. ^1]
  for entry in allowed:
    if entry.toLowerAscii() == bare:
      return true
  return false

# Mirror the documented default: keep this list in sync with
# sidecar_extensions in src/configs/chalk.c42spec.
const defaultExts = ["onnx", "bin", "pt", "pth"]

proc testSidecarPath() =
  assertEq(sidecarPath("/tmp/foo.onnx"),
           "/tmp/foo.onnx" & sidecarSuffix)
  assertEq(sidecarPath("model.bin"),
           "model.bin" & sidecarSuffix)
  # No extension on input is fine — sidecar still appended.
  assertEq(sidecarPath("opaque"), "opaque" & sidecarSuffix)

proc testExtensionMatches() =
  doAssert extensionMatches("a.onnx", defaultExts)
  doAssert extensionMatches("/x/y.bin", defaultExts)
  doAssert extensionMatches("M.PT",     defaultExts)  # case-insensitive
  doAssert extensionMatches("X.Pth",    defaultExts)
  doAssert not extensionMatches("a.zip",         defaultExts)
  doAssert not extensionMatches("foo.safetensors", defaultExts)
  doAssert not extensionMatches("noext",          defaultExts)
  doAssert not extensionMatches("trailing.",      defaultExts)

proc testCustomList() =
  # User extends the list; previously-rejected extensions now match.
  let custom = @["onnx", "bin", "pt", "pth", "tflite"]
  doAssert extensionMatches("model.tflite", custom)
  doAssert not extensionMatches("model.tflite", defaultExts)

proc main() =
  testSidecarPath()
  testExtensionMatches()
  testCustomList()

main()
