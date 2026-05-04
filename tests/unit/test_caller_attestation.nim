## Unit tests for the caller-attestation envelope parser/validator.
##
## `parseAndValidate` is the pure half of `src/plugins/callerAttestation.nim`:
## it consumes a JSON string and returns a populated `EnvelopeState` on
## success, or raises an exception describing the validation failure.
## The plugin's logging / I/O is layered on top and not exercised here —
## these tests cover the wire-format contract documented in
## `docs/design-caller-attestation.md`.
##
## We exercise:
##   - empty input → returns empty state, no exception.
##   - malformed JSON / non-object top-level → exception raised.
##   - version handling: missing / wrong type / wrong number.
##   - bucket shape: each of INFO / HOST_INFO / BUILD_INFO must be an
##     object when present; ARTIFACT_INFO must be an object of objects.
##   - per-artifact entries: required `sha256`, hex-format check
##     (with case-insensitive accept), unexpected-field rejection,
##     optional `info` that may be any JSON type.
##   - top-level X-* keys pass silently; other unknown top-level keys
##     produce a warning (side-effect) but do not raise.
##   - `isHex64` boundary cases.

import std/[
  json,
  strutils,
  tables,
]

import ../../src/plugins/callerAttestation {.all.}

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

template assertRaises(body: untyped) =
  block:
    var raised = false
    try:
      body
    except:
      raised = true
    doAssert raised, "expected an exception to be raised"

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
  doAssert r.artifacts.len == 0
  doAssert r.info      == nil
  doAssert r.hostInfo  == nil
  doAssert r.buildInfo == nil

proc testMalformedJson() =
  assertRaises:
    discard parseAndValidate("not valid json")

proc testNonObjectTopLevel() =
  # intentionally a JSON array, not an object — keep as raw string
  assertRaises:
    discard parseAndValidate("[1, 2, 3]")

# ---------------------------------------------------------------------------
# version
# ---------------------------------------------------------------------------

proc testMissingVersion() =
  assertRaises:
    discard parseAndValidate($(%*{}))

proc testVersionWrongType() =
  assertRaises:
    discard parseAndValidate($(%*{"version": "1"}))

proc testVersionWrongNumber() =
  assertRaises:
    discard parseAndValidate($(%*{"version": 2}))

proc testJustVersion() =
  let r = parseAndValidate($(%*{"version": 1}))
  doAssert r.info      == nil
  doAssert r.hostInfo  == nil
  doAssert r.buildInfo == nil
  doAssert r.artifacts.len == 0

# ---------------------------------------------------------------------------
# host/build/info buckets
# ---------------------------------------------------------------------------

proc testThreeBucketsPopulated() =
  let r = parseAndValidate($(%*{
    "version": 1,
    "CALLER_ATTESTED_INFO":      {"attestor": "crayon"},
    "CALLER_ATTESTED_HOST_INFO": {"host": "laptop"},
    "CALLER_ATTESTED_BUILD_INFO":{"pipeline": "x"},
  }))
  doAssert r.info != nil
  doAssert r.info["attestor"].getStr() == "crayon"
  doAssert r.hostInfo["host"].getStr() == "laptop"
  doAssert r.buildInfo["pipeline"].getStr() == "x"

proc testInfoMustBeObject() =
  for k in ["CALLER_ATTESTED_INFO",
            "CALLER_ATTESTED_HOST_INFO",
            "CALLER_ATTESTED_BUILD_INFO"]:
    let j = %*{"version": 1}
    j[k] = %*"not an object"
    assertRaises:
      discard parseAndValidate($j)

# ---------------------------------------------------------------------------
# unknown top-level keys
# ---------------------------------------------------------------------------

proc testUnknownTopLevelWarns() =
  # warning is emitted via warn() side-effect; verify no exception is raised
  let r = parseAndValidate($(%*{"version": 1, "WHATEVER": {"a": 1}}))
  doAssert r.artifacts.len == 0

proc testXPrefixedTopLevelSilent() =
  # X-* keys must not raise or warn
  let r = parseAndValidate($(%*{"version": 1, "X-experimental": {"a": 1}}))
  doAssert r.artifacts.len == 0

# ---------------------------------------------------------------------------
# Per-artifact entries
# ---------------------------------------------------------------------------

const goodSha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

proc testArtifactGoodEntry() =
  let r = parseAndValidate($(%*{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/abs/path/model.onnx": {
        "sha256": goodSha,
        "info":   {"source": "huggingface"},
      },
    },
  }))
  doAssert r.artifacts.len == 1
  doAssert "/abs/path/model.onnx" in r.artifacts
  let e = r.artifacts["/abs/path/model.onnx"]
  assertEq e.sha256, goodSha
  doAssert e.info != nil
  assertEq e.info["source"].getStr(), "huggingface"

proc testArtifactInfoOptional() =
  let r = parseAndValidate($(%*{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": goodSha}},
  }))
  doAssert r.artifacts["/p"].info == nil

proc testArtifactInfoCanBeAnyJsonType() =
  for inner in [%*"string", %*42, %*[1, 2, 3], %*true, newJNull()]:
    let j = %*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": goodSha, "info": inner}},
    }
    let r = parseAndValidate($j)
    doAssert r.artifacts["/p"].info != nil, "rejected info=" & $inner

proc testArtifactInfoMustBeObject() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": "not an object",
    }))

proc testArtifactEntryMustBeObject() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": "not an object"},
    }))

proc testArtifactMissingSha() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"info": {}}},
    }))

proc testArtifactShaWrongType() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": 123}},
    }))

proc testArtifactShaTooShort() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": "abc"}},
    }))

proc testArtifactShaNonHex() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": "g".repeat(64)}},
    }))

proc testArtifactShaUppercaseAccepted() =
  ## Caller may legitimately produce uppercase hex; chalk normalizes
  ## to lowercase before storage.  Reject anything that isn't hex
  ## once lowercased.
  let upper = goodSha.toUpperAscii()
  let r = parseAndValidate($(%*{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {"sha256": upper}},
  }))
  assertEq r.artifacts["/p"].sha256, goodSha  # stored lowercased

proc testArtifactExtraFieldRejected() =
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {"/p": {
        "sha256": goodSha,
        "info":   {},
        "extra":  "field",
      }},
    }))

proc testMultipleArtifactEntries() =
  let r = parseAndValidate($(%*{
    "version": 1,
    "CALLER_ATTESTED_ARTIFACT_INFO": {
      "/a": {"sha256": goodSha},
      "/b": {"sha256": goodSha, "info": {"x": 1}},
      "/c": {"sha256": goodSha, "info": 42},
    },
  }))
  assertEq r.artifacts.len, 3
  doAssert "/a" in r.artifacts
  doAssert "/b" in r.artifacts
  doAssert "/c" in r.artifacts
  doAssert r.artifacts["/a"].info == nil
  doAssert r.artifacts["/b"].info != nil
  doAssert r.artifacts["/c"].info != nil

# ---------------------------------------------------------------------------
# Failure semantics: any per-entry rejection discards the whole envelope
# ---------------------------------------------------------------------------

proc testOneBadEntryDiscardsAll() =
  ## /good is valid, /bad has a non-hex sha — the whole envelope is
  ## rejected via exception, so no state is returned.
  assertRaises:
    discard parseAndValidate($(%*{
      "version": 1,
      "CALLER_ATTESTED_ARTIFACT_INFO": {
        "/good": {"sha256": goodSha},
        "/bad":  {"sha256": "nope"},
      },
    }))

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
