import std/[
  os,
  streams,
  strutils,
]
import ../../src/utils/file_string_stream {.all.}

template assertEq(a, b: untyped) =
  doAssert a == b, "\"" & $a & "\" != \"" & $b & "\""

proc test(load: bool) =
  var s = newFileStringStream("one")
  if load:
    s.load()

  assertEq(len(s), 25)
  assertEq(
    s.readAll().toHex(),
    "hello".toHex() &
    "08" &
    "1000" &
    "2000" & "0000" &
    "4000" & "0000" & "0000" & "0000" &
    "world".toHex(),
  )
  assertEq(s[0..<5], "hello")
  assertEq(s[20..<25], "world")
  assertEq(s[20..^1], "world")
  assertEq(s[20..^2], "worl")
  assertEq(readInt[uint8](s, 5), 8'u8)
  assertEq(readInt[uint16](s, 6), 16'u16)
  assertEq(readInt[uint32](s, 8), 32u32)
  assertEq(readInt[uint64](s, 12), 64u64)

  s[24] = 'D'
  assertEq(s[20..^1], "worlD")

  s[2] = '1'
  s[3] = '1'
  assertEq(s[0..<5], "he11o")

  s[5] = '\n'
  assertEq(readInt[uint8](s, 5), uint8('\n'))

  s[22] = 'n'
  assertEq(len(s), 25)
  s[23] = "derful"
  assertEq(len(s), 29)
  assertEq(s[20..<26], "wonder")
  assertEq(s[20..<29], "wonderful")
  assertEq(s[20..^1], "wonderful")
  assertEq(s[23..<29], "derful")
  assertEq(s[23..<28], "derfu")
  assertEq(s[24..<29], "erful")
  assertEq(s[26..<29], "ful")
  assertEq(s[25..<28], "rfu")

  assertEq(s[0..<5], "he11o")

  assertEq(
    s.readAll().toHex(),
    "he11o".toHex() &
    "0A" &
    "1000" &
    "2000" & "0000" &
    "4000" & "0000" & "0000" & "0000" &
    "wonderful".toHex(),
  )

  s.writeAll("hello")
  assertEq(s.readAll(), "hello")

proc main =
  let s = newFileStream("one", fmWrite)
  s.write("hello")
  s.write(8'u8)
  s.write(16'u16)
  s.write(32'u32)
  s.write(64'u64)
  s.write("world")
  s.close()

  echo(newFileStream("one").readAll().toHex())

  try:
    test(load = false)
    test(load = true)
  finally:
    removeFile("one")

main()
