## Unit tests for the caller-attestation envelope parser/validator.
##
## `parseAndValidate` is the pure half of `src/plugins/callerAttestation.nim`:
## it consumes a JSON string and returns a `ValidationResult` containing
## either a populated `EnvelopeState` or an error message (plus any
## advisory warnings).  The plugin's logging / I/O is layered on top
## and not exercised here — these tests cover the wire-format contract
## documented in `docs/design-caller-attestation.md`.
##
## We exercise:
##   - empty input → not valid, no error (channel-not-set is a non-event).
##   - malformed JSON / non-object top-level → errMsg.
##   - version handling: missing / wrong type / wrong number.
##   - bucket shape: each of INFO / HOST_INFO / BUILD_INFO must be an
##     object when present; ARTIFACT_INFO must be an object of objects.
##   - per-artifact entries: required `sha256`, hex-format check
##     (with case-insensitive accept), unexpected-field rejection,
##     optional `info` that may be any JSON type.
##   - top-level X-* keys pass silently; other unknown top-level keys
##     produce a warning but do not invalidate.
##   - `isHex64` boundary cases.

import std/[
  json,
  options,
  strutils,
  tables,
]

import ../../src/plugins/callerAttestation {.all.}

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

# ---------------------------------------------------------------------------
# isHex64
# ---------------------------------------------------------------------------

proc testIsHex64() =
  let lower64 = "0123456789abcdef".repeat(4)
  doAssert lower64.len == 64
  doAssert isHex64(lower64)

  doAssert not isHex64("")
  doAssert not isHex64("a")                          # too short
  doAssert not isHex64(lower64 & "0")                # too long
  doAssert not isHex64("g".repeat(64))               # non-hex char
  doAssert not isHex64("ABCDEF" & "0".repeat(58))    # uppercase not allowed
                                                     # (callers must
                                                     # lowercase first)

# ---------------------------------------------------------------------------
# Empty / malformed
# ---------------------------------------------------------------------------

proc testEmptyInput() =
  let r = parseAndValidate("")
  doAssert r.errMsg.len == 0
  doAssert not r.state.valid
  doAssert r.warnings.len == 0
  doAssert r.state.artifacts.len == 0

proc testMalformedJson() =
  let r = parseAndValidate("not valid json")
  doAssert r.errMsg.len > 0
  doAssert "malformed JSON" in r.errMsg
  doAssert not r.state.valid

proc testNonObjectTopLevel() =
  let r = parseAndValidate("[1, 2, 3]")
  doAssert r.errMsg.len > 0
  doAssert "top-level must be a JSON object" in r.errMsg
  doAssert not r.state.valid

# ---------------------------------------------------------------------------
# version
# ---------------------------------------------------------------------------

proc testMissingVersion() =
  let r = parseAndValidate("""{}""")
  doAssert "missing required `version`" in r.errMsg
  doAssert not r.state.valid

proc testVersionWrongType() =
  let r = parseAndValidate("""{"version":"1"}""")
  doAssert "unsupported `version`" in r.errMsg
  doAssert not r.state.valid

proc testVersionWrongNumber() =
  let r = parseAndValidate("""{"version":2}""")
  doAssert "unsupported `version`" in r.errMsg
  doAssert not r.state.valid

proc testJustVersion() =
  let r = parseAndValidate("""{"version":1}""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.state.info     == nil
  doAssert r.state.hostInfo == nil
  doAssert r.state.buildInfo == nil
  doAssert r.state.artifacts.len == 0

# ---------------------------------------------------------------------------
# host/build/info buckets
# ---------------------------------------------------------------------------

proc testThreeBucketsPopulated() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_INFO":      {"attestor":"crayon"},
    "CALLER_ATTESTED_HOST_INFO": {"host":"laptop"},
    "CALLER_ATTESTED_BUILD_INFO":{"pipeline":"x"}
  }""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.state.info != nil
  doAssert r.state.info["attestor"].getStr() == "crayon"
  doAssert r.state.hostInfo["host"].getStr() == "laptop"
  doAssert r.state.buildInfo["pipeline"].getStr() == "x"

proc testInfoMustBeObject() =
  for k in ["CALLER_ATTESTED_INFO",
            "CALLER_ATTESTED_HOST_INFO",
            "CALLER_ATTESTED_BUILD_INFO"]:
    let raw = """{"version":1,"""" & k & """":"not an object"}"""
    let r = parseAndValidate(raw)
    doAssert r.errMsg.len > 0, "expected rejection for non-object " & k
    doAssert ("'" & k & "' must be a JSON object") in r.errMsg
    doAssert not r.state.valid

# ---------------------------------------------------------------------------
# unknown top-level keys
# ---------------------------------------------------------------------------

proc testUnknownTopLevelWarns() =
  let r = parseAndValidate("""{"version":1,"WHATEVER":{"a":1}}""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.warnings.len == 1
  doAssert "unknown top-level key 'WHATEVER'" in r.warnings[0]

proc testXPrefixedTopLevelSilent() =
  let r = parseAndValidate("""{"version":1,"X-experimental":{"a":1}}""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.warnings.len == 0

# ---------------------------------------------------------------------------
# Per-artifact entries
# ---------------------------------------------------------------------------

const goodSha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

proc testArtifactGoodEntry() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/abs/path/model.onnx": {
        "sha256": """" & goodSha & """",
        "info":   {"source": "huggingface"}
      }
    }
  }""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.state.artifacts.len == 1
  doAssert "/abs/path/model.onnx" in r.state.artifacts
  let e = r.state.artifacts["/abs/path/model.onnx"]
  assertEq e.sha256, goodSha
  doAssert e.info != nil
  assertEq e.info["source"].getStr(), "huggingface"

proc testArtifactInfoOptional() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/p": {"sha256": """" & goodSha & """"}
    }
  }""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  doAssert r.state.artifacts["/p"].info == nil

proc testArtifactInfoCanBeAnyJsonType() =
  for inner in [""""string"""", "42", "[1,2,3]", "true", "null"]:
    let raw = """{"version":1,"CALLER_ATTESTED_ARTIFACT_INFO":{
      "/p":{"sha256":"""" & goodSha & """","info":""" & inner & "}}}"
    let r = parseAndValidate(raw)
    doAssert r.errMsg.len == 0, "rejected info=" & inner & ": " & r.errMsg
    doAssert r.state.valid
    doAssert r.state.artifacts["/p"].info != nil

proc testArtifactInfoMustBeObject() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": "not an object"
  }""")
  doAssert "'CALLER_ATTESTED_ARTIFACT_INFO' must be a JSON object" in r.errMsg
  doAssert not r.state.valid

proc testArtifactEntryMustBeObject() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": "not an object"}
  }""")
  doAssert "entry for '/p' must be an object" in r.errMsg
  doAssert not r.state.valid

proc testArtifactMissingSha() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"info": {}}}
  }""")
  doAssert "is missing required string 'sha256'" in r.errMsg
  doAssert not r.state.valid

proc testArtifactShaWrongType() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": 123}}
  }""")
  doAssert "is missing required string 'sha256'" in r.errMsg
  doAssert not r.state.valid

proc testArtifactShaTooShort() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": "abc"}}
  }""")
  doAssert "invalid 'sha256'" in r.errMsg
  doAssert not r.state.valid

proc testArtifactShaNonHex() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": """" &
      "g".repeat(64) & """"}}
  }""")
  doAssert "invalid 'sha256'" in r.errMsg
  doAssert not r.state.valid

proc testArtifactShaUppercaseAccepted() =
  ## Caller may legitimately produce uppercase hex; chalk normalizes
  ## to lowercase before storage.  Reject anything that isn't hex
  ## once lowercased.
  let upper = goodSha.toUpperAscii()
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": """" & upper & """"}}
  }""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  assertEq r.state.artifacts["/p"].sha256, goodSha  # stored lowercased

proc testArtifactExtraFieldRejected() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {
      "sha256": """" & goodSha & """",
      "info":   {},
      "extra":  "field"
    }}
  }""")
  doAssert "has unexpected field 'extra'" in r.errMsg
  doAssert not r.state.valid

proc testMultipleArtifactEntries() =
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/a": {"sha256": """" & goodSha & """"},
      "/b": {"sha256": """" & goodSha & """","info":{"x":1}},
      "/c": {"sha256": """" & goodSha & """","info":42}
    }
  }""")
  doAssert r.errMsg.len == 0
  doAssert r.state.valid
  assertEq r.state.artifacts.len, 3
  doAssert "/a" in r.state.artifacts
  doAssert "/b" in r.state.artifacts
  doAssert "/c" in r.state.artifacts
  doAssert r.state.artifacts["/a"].info == nil
  doAssert r.state.artifacts["/b"].info != nil
  doAssert r.state.artifacts["/c"].info != nil

# ---------------------------------------------------------------------------
# Failure semantics: any per-entry rejection discards the whole envelope
# ---------------------------------------------------------------------------

proc testOneBadEntryDiscardsAll() =
  ## /good is valid, /bad has a non-hex sha — the envelope is rejected
  ## as a whole, so neither entry should appear in state.artifacts.
  let r = parseAndValidate("""{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/good": {"sha256": """" & goodSha & """"},
      "/bad":  {"sha256": "nope"}
    }
  }""")
  doAssert r.errMsg.len > 0
  doAssert not r.state.valid

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

proc main() =
  testIsHex64()
  testEmptyInput()
  testMalformedJson()
  testNonObjectTopLevel()
  testMissingVersion()
  testVersionWrongType()
  testVersionWrongNumber()
  testJustVersion()
  testThreeBucketsPopulated()
  testInfoMustBeObject()
  testUnknownTopLevelWarns()
  testXPrefixedTopLevelSilent()
  testArtifactGoodEntry()
  testArtifactInfoOptional()
  testArtifactInfoCanBeAnyJsonType()
  testArtifactInfoMustBeObject()
  testArtifactEntryMustBeObject()
  testArtifactMissingSha()
  testArtifactShaWrongType()
  testArtifactShaTooShort()
  testArtifactShaNonHex()
  testArtifactShaUppercaseAccepted()
  testArtifactExtraFieldRejected()
  testMultipleArtifactEntries()
  testOneBadEntryDiscardsAll()

main()
