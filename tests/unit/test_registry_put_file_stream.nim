## Unit tests for the chunked blob-upload offset decision in
## `src/docker/registry.nim`.
##
## These exercise the real (non-exported) `nextChunkOffset` and `nextStartAt`
## procs - imported via `{.all.}` - that decide the next upload position after
## each chunk response. The full `layerPutFileStream` loop only adds HTTP I/O
## and bookkeeping (endAt computation, Location refresh) around these procs, so
## driving them directly with scripted `Response` values is a faithful slice of
## the loop's control flow without standing up a registry.
##
## The headline case is the grouped-001 regression: once `trustSentPosition`
## is latched and `startAt` has advanced past the registry's lagging Range, a
## later 416 carrying that same stale Range must recover (advance by the bytes
## we sent) instead of re-deriving the offset from the stale Range and tripping
## `nextStartAt`'s backward-range guard with "Range response header went
## backwards".

import std/[
  httpclient,
  strutils,
]
import ../../src/utils/uri
import ../../src/docker/registry {.all.}

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

template assertRaisesMsg(needle: string, body: untyped) =
  block:
    var
      raised = false
      got    = ""
    try:
      body
    except ValueError:
      raised = true
      got    = getCurrentExceptionMsg()
    doAssert raised, "expected ValueError containing: " & needle
    doAssert needle in got, "expected message containing " & needle & " got: " & got

proc resp(status: string, rangeHeader = ""): Response =
  result = Response(status: status, headers: newHttpHeaders())
  if rangeHeader.len > 0:
    result.headers["Range"] = rangeHeader

proc digestResp(contentDigest: string): Response =
  result = Response(status: "201 Created", headers: newHttpHeaders())
  if contentDigest.len > 0:
    result.headers["Docker-Content-Digest"] = contentDigest

proc digestPairs(s: string): int =
  ## count "digest=" query-pair occurrences in a rendered URL
  var i = 0
  while true:
    let idx = s.find("digest=", i)
    if idx < 0: break
    inc result
    i = idx + "digest=".len

const
  # a layer whose locally computed digest is blobHash; imageRef renders it as
  # "sha256:" & blobHash, which is exactly what we send as the ?digest= finalize.
  blobHash   = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  blobDigest = "sha256:" & blobHash
  # a structural DockerImage tuple (repo, tag, digest); imageRef renders it as
  # "sha256:" & blobHash.
  sampleLayer = (repo: "test", tag: "", digest: blobHash)

# ---------------------------------------------------------------------------
# A 2xx with an advancing Range advances by the registry-reported position and
# resets the retry counter, with no latch.
# ---------------------------------------------------------------------------
proc test_advancing_range() =
  let (startAt, attempts, trust) = resp("201 Created", "0-9").nextChunkOffset(
    startAt           = 0,
    endAt             = 9,
    attempts          = 1,
    trustSentPosition = false,
  )
  assertEq(startAt, 10)
  assertEq(attempts, 1)
  assertEq(trust, false)

# ---------------------------------------------------------------------------
# Two 2xx responses with a non-advancing (stale) Range latch
# trustSentPosition and advance startAt past the registry-reported position.
# This is the state that the 416 regression depends on, and it works on the
# non-416 path both before and after the fix - that asymmetry is the bug.
# ---------------------------------------------------------------------------
proc test_stale_2xx_latches_trust(): (int, int, bool) =
  # startAt has reached 10; the registry keeps reporting Range "0-9".
  var (startAt, attempts, trust) = resp("201 Created", "0-9").nextChunkOffset(
    startAt           = 10,
    endAt             = 19,
    attempts          = 1,
    trustSentPosition = false,
  )
  # Range did not advance: same position, attempts incremented, not yet latched.
  assertEq(startAt, 10)
  assertEq(attempts, 2)
  assertEq(trust, false)

  (startAt, attempts, trust) = resp("201 Created", "0-9").nextChunkOffset(
    startAt           = startAt,
    endAt             = 19,
    attempts          = attempts,
    trustSentPosition = trust,
  )
  # attempts exceeded the stall budget: latch and advance by what we sent.
  assertEq(startAt, 20)
  assertEq(attempts, 1)
  assertEq(trust, true)
  return (startAt, attempts, trust)

# ---------------------------------------------------------------------------
# 416 in sent-position mode with a stale Range (rangeEnd+1 <= startAt) raises
# immediately rather than advancing blind, because the registry is hallucinating
# the same stale value that caused the latch to engage.
# ---------------------------------------------------------------------------
proc test_416_trusted_stale_range_raises() =
  let (startAt, _, _) = test_stale_2xx_latches_trust()
  assertEq(startAt, 20)

  assertRaisesMsg("stale Range 0-9 at position 20"):
    discard resp("416 Range Not Satisfiable", "0-9").nextChunkOffset(
      startAt           = startAt,
      endAt             = 29,
      attempts          = 1,
      trustSentPosition = true,
    )

# ---------------------------------------------------------------------------
# 416 in sent-position mode with a Range pointing within the current chunk
# (rangeEnd+1 > startAt) is honored: the registry partially stored the chunk
# and returned a real resume offset.
# ---------------------------------------------------------------------------
proc test_416_trusted_midchunk_range_honors() =
  # Sent bytes 20-29; registry reports Range "0-24" (confirmed up to byte 24).
  let (nextAt, attempts, trust) = resp("416 Range Not Satisfiable", "0-24").nextChunkOffset(
    startAt           = 20,
    endAt             = 29,
    attempts          = 1,
    trustSentPosition = true,
  )
  assertEq(nextAt, 25)
  assertEq(attempts, 1)
  assertEq(trust, true)

# ---------------------------------------------------------------------------
# 416 in sent-position mode with no Range header raises immediately.
# ---------------------------------------------------------------------------
proc test_416_trusted_missing_range_raises() =
  assertRaisesMsg("missing Range header"):
    discard resp("416 Range Not Satisfiable").nextChunkOffset(
      startAt           = 20,
      endAt             = 29,
      attempts          = 1,
      trustSentPosition = true,
    )

# ---------------------------------------------------------------------------
# The fix must not weaken the legitimate (non-latched) 416 handling: a 416 that
# keeps reporting the same stale Range is still bounded by the attempt budget
# and aborts with the "registry rejected chunk" message.
# ---------------------------------------------------------------------------
proc test_416_bounded_abort_without_trust() =
  var (startAt, attempts, trust) = resp("416 Range Not Satisfiable", "0-9").nextChunkOffset(
    startAt           = 10,
    endAt             = 19,
    attempts          = 1,
    trustSentPosition = false,
  )
  assertEq(startAt, 10)
  assertEq(attempts, 2)
  assertEq(trust, false)

  assertRaisesMsg("registry rejected chunk at position 10 after 3 attempts"):
    discard resp("416 Range Not Satisfiable", "0-9").nextChunkOffset(
      startAt           = startAt,
      endAt             = 19,
      attempts          = attempts,
      trustSentPosition = trust,
    )

# ---------------------------------------------------------------------------
# A 416 whose Range advances is retried at the new position without aborting.
# ---------------------------------------------------------------------------
proc test_416_advancing_retries() =
  let (startAt, attempts, trust) = resp("416 Range Not Satisfiable", "0-19").nextChunkOffset(
    startAt           = 10,
    endAt             = 19,
    attempts          = 1,
    trustSentPosition = false,
  )
  assertEq(startAt, 20)
  assertEq(attempts, 1)
  assertEq(trust, false)

# ---------------------------------------------------------------------------
# A finalize PUT whose Docker-Content-Digest matches the uploaded layer digest
# is accepted and returned unchanged.
# ---------------------------------------------------------------------------
proc test_finalize_digest_matches() =
  assertEq(digestResp(blobDigest).finalizeBlobDigest(sampleLayer), blobDigest)

# ---------------------------------------------------------------------------
# grouped-002 regression: once trustSentPosition is latched the finalize PUT is
# the only integrity gate, so a well-formed but non-matching Docker-Content-Digest
# must fail closed instead of being reported as a successful push. validateDigest
# alone (format-only) does not catch this - the equality check against the
# uploaded layer digest does.
# ---------------------------------------------------------------------------
proc test_finalize_digest_mismatch_raises() =
  let wrongDigest = "sha256:" & repeat('0', 64)
  assertRaisesMsg("does not match uploaded layer digest"):
    discard digestResp(wrongDigest).finalizeBlobDigest(sampleLayer)

# ---------------------------------------------------------------------------
# A missing Docker-Content-Digest header still fails closed (unchanged).
# ---------------------------------------------------------------------------
proc test_finalize_digest_missing_header_raises() =
  assertRaisesMsg("missing Docker-Content-Digest"):
    discard digestResp("").finalizeBlobDigest(sampleLayer)

# ---------------------------------------------------------------------------
# grouped-004: the per-chunk request target is derived from the stable upload
# location at the call site, not by mutating a shared `location`. A non-final
# chunk is a PATCH to the bare location, carrying no ?digest= finalize query.
# ---------------------------------------------------------------------------
proc test_chunk_target_intermediate_is_bare_patch() =
  let base = parseUri("https://reg.example.com/v2/test/blobs/uploads/uuid?_state=abc")
  let (httpMethod, url) = chunkUploadTarget(base, sampleLayer, isFinal = false)
  assertEq(httpMethod, HttpPatch)
  assertEq($url, $base)
  assertEq(digestPairs($url), 0)

# ---------------------------------------------------------------------------
# The final chunk is a PUT whose URL carries exactly one ?digest= finalize pair.
# ---------------------------------------------------------------------------
proc test_chunk_target_final_is_put_with_digest() =
  let base = parseUri("https://reg.example.com/v2/test/blobs/uploads/uuid?_state=abc")
  let (httpMethod, url) = chunkUploadTarget(base, sampleLayer, isFinal = true)
  assertEq(httpMethod, HttpPut)
  assertEq(digestPairs($url), 1)
  doAssert blobHash in $url, "finalize URL must carry the layer digest hash: " & $url

# ---------------------------------------------------------------------------
# grouped-004 regression: re-deriving the final target from the SAME stable
# base location (as happens when a final attempt re-loops without a Location
# refresh) never stacks a second ?digest= pair, because the digest is added at
# the call site against a fresh copy rather than mutated onto a shared URL.
# Pre-fix the shared-`location` mutation appended a duplicate digest on re-loop.
# ---------------------------------------------------------------------------
proc test_chunk_target_final_idempotent() =
  let base = parseUri("https://reg.example.com/v2/test/blobs/uploads/uuid?_state=abc")
  let (_, first)  = chunkUploadTarget(base, sampleLayer, isFinal = true)
  let (_, second) = chunkUploadTarget(base, sampleLayer, isFinal = true)
  assertEq(digestPairs($first), 1)
  assertEq(digestPairs($second), 1)
  assertEq($first, $second)

when isMainModule:
  test_advancing_range()
  discard test_stale_2xx_latches_trust()
  test_416_trusted_stale_range_raises()
  test_416_trusted_midchunk_range_honors()
  test_416_trusted_missing_range_raises()
  test_416_bounded_abort_without_trust()
  test_416_advancing_retries()
  test_finalize_digest_matches()
  test_finalize_digest_mismatch_raises()
  test_finalize_digest_missing_header_raises()
  test_chunk_target_intermediate_is_bare_patch()
  test_chunk_target_final_is_put_with_digest()
  test_chunk_target_final_idempotent()
  echo "test_registry_put_file_stream: all tests passed"
