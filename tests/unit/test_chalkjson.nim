import std/[
  json,
  streams,
]
import ../../src/chalkjson {.all.}
import ../../src/[
  utils/json,
]

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc main() =
  let data = """
[
  0,
  1,
  -1,
  5.1,
  -5.1,
  1.5e0,
  1.5E5,
  -1.5E25,
  1.5e+0,
  1.5E+12,
  1.5e-7,
  -1.5e-15,
  true,
  false,
  null,
  "hello",
  {
    "string": "bar",
    "null": null,
    "array": ["0", 1, {}],
    "int": 1,
    "neg": -1,
    "zero": 0,
    "float": 1.5,
    "negfloat": -1.5,
    "bool": true
  }
]
    """

  assertEq(
    parseJson(data).nimJsonToBox().boxToJson().parseJson(),
    parseJson(data),
  )
  assertEq(
    chalkParseJson(newStringStream(data)).valueFromJson("").boxToJson().parseJson(),
    parseJson(data),
  )

main()
