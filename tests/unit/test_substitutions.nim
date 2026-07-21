import "../../src/utils/substitutions"

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

template checkRaises(exc: typedesc, body: untyped) =
  block:
    var raised = false
    try:
      body
    except exc:
      raised = true
    doAssert raised, "expected " & astToStr(exc) & " to be raised but it was not"

proc identity(key: string): string = key

proc testNormalPath() =
  # No placeholders — passthrough
  check applySubstitutions("hello.world", identity) == "hello.world"

  # Single placeholder
  check applySubstitutions("{foo}", identity) == "FOO"

  # Multiple placeholders
  check applySubstitutions("{a}.{b}.{c}", identity) == "A.B.C"

  # Keys are uppercased before lookup
  check applySubstitutions("{lower}", identity) == "LOWER"
  check applySubstitutions("{UPPER}", identity) == "UPPER"
  check applySubstitutions("{Mixed}", identity) == "MIXED"

  # Literal text mixed with placeholders
  check applySubstitutions("prefix.{key}.suffix", identity) == "prefix.KEY.suffix"

  # Lookup return value is spliced verbatim
  check applySubstitutions(
    "{x}",
    proc(key: string): string = "replaced",
  ) == "replaced"

proc testEmptyBraces() =
  # Empty {} raises ValueError
  checkRaises(ValueError):
    discard applySubstitutions("{}.foo", identity)
  checkRaises(ValueError):
    discard applySubstitutions("a.{}.b", identity)

proc testMalformedBraces() =
  # Repeated '{' without closing '}'
  checkRaises(ValueError):
    discard applySubstitutions("{a{b}", identity)

  # '}' without preceding '{'
  checkRaises(ValueError):
    discard applySubstitutions("a}b", identity)

  # Trailing unclosed '{'
  checkRaises(ValueError):
    discard applySubstitutions("{abc", identity)

  # Trailing '{' with no key
  checkRaises(ValueError):
    discard applySubstitutions("foo.{", identity)

testNormalPath()
testEmptyBraces()
testMalformedBraces()
echo "All substitution tests passed."
