import ../../src/types
import ../../src/docker/ids
import ../../src/policy/api
import ../../src/policy/rules/golden_images

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const
  digest = "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"
  other  = "0000000000000000000000000000000000000000000000000000000000000000"

proc check(image: string, allowed: seq[AllowedImage], digests: seq[string] = @[]): MatchResult =
  return parseImage(image, defaultTag = "").checkImage(digests, allowed).result

proc main() =
  assert globMatch("*", "")
  assert globMatch("a*c", "abbbc")
  assert globMatch("a?c", "abc")
  assert not globMatch("a?c", "ac")
  assert globMatch("cgr.dev/chainguard/*", "cgr.dev/chainguard/static/sub")
  assert not globMatch("alpine", "alpine2")

  let golden: seq[AllowedImage] = @[
    ("glob", "docker.io/library/alpine:*"),
    ("glob", "cgr.dev/chainguard/*"),
  ]
  # docker hub short names are normalized on both sides
  assertEq(check("alpine", golden), mrAllowed)
  assertEq(check("alpine:3.20", golden), mrAllowed)
  assertEq(check("library/alpine:3.20", golden), mrAllowed)
  assertEq(check("docker.io/library/alpine:3.20", golden), mrAllowed)
  assertEq(check("index.docker.io/library/alpine", golden), mrAllowed)
  assertEq(check("alpine@sha256:" & digest, golden), mrAllowed)
  assertEq(check("cgr.dev/chainguard/static:latest", golden), mrAllowed)
  assertEq(check("python:3.12-slim", golden), mrDenied)
  assertEq(check("myregistry.com/library/alpine:3.20", golden), mrDenied)
  assertEq(check("cgr.dev/other/static", golden), mrDenied)
  assertEq(check("scratch", golden), mrAllowed)

  # tag patterns
  let tagged: seq[AllowedImage] = @[("glob", "alpine:3.*")]
  assertEq(check("alpine:3.20", tagged), mrAllowed)
  assertEq(check("alpine:edge", tagged), mrDenied)
  assertEq(check("alpine", tagged), mrDenied)
  let latest: seq[AllowedImage] = @[("glob", "alpine:latest")]
  assertEq(check("alpine", latest), mrAllowed)
  assertEq(check("alpine@sha256:" & digest, latest), mrDenied)

  # digests
  let pinned: seq[AllowedImage] = @[("digest", "ghcr.io/acme/base@sha256:" & digest)]
  assertEq(check("ghcr.io/acme/base:1", pinned, @[digest]), mrAllowed)
  assertEq(check("ghcr.io/acme/other:1", pinned, @[digest]), mrDenied)
  assertEq(check("ghcr.io/acme/base:1", pinned, @[other]), mrDenied)
  assertEq(check("ghcr.io/acme/base:1", pinned), mrUnknown)
  let anyRepo: seq[AllowedImage] = @[("digest", "sha256:" & digest)]
  assertEq(check("ghcr.io/acme/anything", anyRepo, @[other, digest]), mrAllowed)

  # unknown kinds cannot decide unless another entry matches
  let future: seq[AllowedImage] = @[("signed_by", "acme"), ("glob", "alpine")]
  assertEq(check("python", future), mrUnknown)
  assertEq(check("alpine", future), mrAllowed)

  # empty allowlist denies everything external
  assertEq(check("alpine", @[]), mrDenied)

  # check_copy_from also covers images mounted by RUN
  var subjects: seq[PolicySubject]
  for source in ["from", "copy_from", "mount_from"]:
    subjects.add(PolicySubject(image: parseImage("busybox"), raw: "busybox", source: source))
  assertEq(GoldenImagesConfig(checkCopyFrom: true).check(subjects).len, 3)
  assertEq(GoldenImagesConfig(checkCopyFrom: false).check(subjects).len, 1)

main()
