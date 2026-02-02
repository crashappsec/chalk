import std/sequtils
import ../../src/utils/strings

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc main() =
  let seps = {' ', ','}
  assertEq(
    quotedWords("""bearer foo="one,two",baz="baz"""", seps).toSeq(),
    @[
      "bearer",
      "foo=one,two",
      "baz=baz",
    ],
  )
  assertEq(
    quotedWords("""bearer foo="one,two",baz="baz", basic one="two",three="four,five"""", seps).toSeq(),
    @[
      "bearer",
      "foo=one,two",
      "baz=baz",
      "basic",
      "one=two",
      "three=four,five",
    ],
  )

main()
