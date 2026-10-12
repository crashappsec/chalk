import ../../src/policy/purl

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc matches(pattern, purl: string): PurlMatch =
  parsePurlPattern(pattern).matches(purl).result

proc testParts() =
  assertEq(purlParts("pkg:npm/%40angular/core@16.0.0"), ("npm/@angular/core", "16.0.0"))
  assertEq(purlParts("pkg:npm/@angular/core"), ("npm/@angular/core", ""))
  assertEq(purlParts("pkg:deb/debian/libc6@1:2.36-9?arch=amd64#sub"), ("deb/debian/libc6", "1:2.36-9"))
  assertEq(purlParts("PKG:PyPI/Django_Rest.Framework@1.0"), ("pypi/django-rest-framework", "1.0"))
  assertEq(purlParts("pkg:golang/github.com/google/uuid@v1.6.0"), ("golang/github.com/google/uuid", "v1.6.0"))
  # in a pattern `?` is a wildcard unless qualifiers follow
  assertEq(purlParts("pkg:npm/lib?@1.?", pattern = true), ("npm/lib?", "1.?"))
  assertEq(purlParts("pkg:npm/lib?@1.?arch=amd64", pattern = true), ("npm/lib?", "1."))
  assertEq(purlType("pkg:golang/github.com/google/uuid@v1.6.0"), "golang")
  assertEq(purlType("PKG:PyPI/x@1"), "pypi")
  assertEq(purlType("not-a-purl"), "")

proc testPatterns() =
  for bad in ["npm/lodash", "pkg:npm", "pkg:npm/lodash@<abc", "pkg:npm/lodash@=>1", "pkg:npm/lodash@<1.0.post1"]:
    try:
      discard parsePurlPattern(bad)
      doAssert false, "accepted " & bad
    except ValueError:
      discard
  assertEq(parsePurlPattern("pkg:npm/x@1").raw, "pkg:npm/x@1")
  assertEq(matches("pkg:npm/event-stream@3.3.6", "pkg:npm/event-stream@3.3.6"), pmMatch)
  assertEq(matches("pkg:npm/event-stream@3.3.6", "pkg:npm/event-stream@3.3.5"), pmNoMatch)
  assertEq(matches("pkg:npm/event-stream", "pkg:npm/event-stream@4.0.0"), pmMatch)
  assertEq(matches("pkg:npm/event-stream", "pkg:npm/event-stream-x@4.0.0"), pmNoMatch)
  assertEq(matches("pkg:pypi/*colourama*", "pkg:pypi/colourama@0.1.0"), pmMatch)
  assertEq(matches("pkg:pypi/django_rest", "pkg:pypi/django-rest@1.0"), pmMatch)
  assertEq(matches("pkg:*/lodash", "pkg:npm/lodash@4.17.20"), pmMatch)
  assertEq(matches("pkg:NPM/LoDash", "pkg:npm/lodash@4.17.20"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*", "pkg:npm/%40angular/core@16.0.0"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*@16.*", "pkg:npm/%40angular/core@16.0.0"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*@15.*", "pkg:npm/%40angular/core@16.0.0"), pmNoMatch)
  assertEq(matches("pkg:golang/github.com/google/uuid@1.6.0", "pkg:golang/github.com/google/uuid@v1.6.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash@4.17.20"), pmMatch)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash@4.17.21"), pmNoMatch)
  assertEq(matches("pkg:npm/lodash@>=4.0,<4.17.21", "pkg:npm/lodash@3.10.1"), pmNoMatch)
  assertEq(matches("pkg:npm/lodash@>=4.0,<4.17.21", "pkg:npm/lodash@4.1.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@==4.1", "pkg:npm/lodash@4.1.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@!=4.1.0", "pkg:npm/lodash@4.1.0"), pmNoMatch)
  assertEq(matches("pkg:golang/github.com/google/uuid@>=1.5", "pkg:golang/github.com/google/uuid@v1.6.0"), pmMatch)
  assertEq(matches("pkg:nuget/x@<4.0.0.1", "pkg:nuget/x@4.0.0.0"), pmMatch)
  assertEq(matches("pkg:npm/x@<1.0.0-rc.10", "pkg:npm/x@1.0.0-rc.9"), pmMatch)
  assertEq(matches("pkg:golang/x@>=2.0.0", "pkg:golang/x@v2.0.0+incompatible"), pmMatch)
  # only versions chalk can order are compared
  assertEq(matches("pkg:pypi/x@<2", "pkg:pypi/x@1.0.post1"), pmUnknown)
  assertEq(matches("pkg:deb/debian/libc6@<2.37", "pkg:deb/debian/libc6@1:2.36-9"), pmUnknown)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash"), pmUnknown)
  assertEq(matches("pkg:npm/lodash", ""), pmNoMatch)

proc testQuestionGlobsAndQualifiers() =
  assertEq(matches("pkg:npm/lib?", "pkg:npm/libx@1.0.0"), pmMatch)
  assertEq(matches("pkg:npm/lib?", "pkg:npm/lib@1.0.0"), pmNoMatch)
  assertEq(matches("pkg:npm/x@1.?", "pkg:npm/x@1.2"), pmMatch)
  assertEq(matches("pkg:npm/x@1.?", "pkg:npm/x@1.22"), pmNoMatch)
  assertEq(matches("pkg:npm/lib??@1.?", "pkg:npm/libxy@1.2"), pmMatch)
  assertEq(matches("pkg:npm/lib%3F@1.%3F", "pkg:npm/libx@1.2"), pmMatch)
  assertEq(matches("pkg:npm/lib?@1.?arch=amd64&os=linux", "pkg:npm/libx@1."), pmMatch)
  assertEq(matches("pkg:npm/lib?@1.??arch=amd64", "pkg:npm/libx@1.2?arch=arm64"), pmMatch)
  assertEq(matches("pkg:npm/x@1.2?arch=amd64#sub", "pkg:npm/x@1.2?arch=arm64"), pmMatch)
  # Percent-encoded @ belongs to the name; + is not a space.
  assertEq(matches("pkg:generic/a%40b@1+meta", "pkg:generic/a%40b@1+meta"), pmMatch)

proc testFirstMatch() =
  let patterns = @[parsePurlPattern("pkg:deb/debian/libc6@<2.37"),
                   parsePurlPattern("pkg:deb/debian/*")]
  assertEq(patterns.firstMatch("pkg:deb/debian/libc6@1:2.36-9"), (pmMatch, "pkg:deb/debian/*"))
  let (res, reason) = patterns[0 .. 0].firstMatch("pkg:deb/debian/libc6@1:2.36-9")
  assertEq(res, pmUnknown)
  doAssert reason.len > 0
  assertEq(patterns.firstMatch("pkg:npm/x@1"), (pmNoMatch, ""))

testParts()
testPatterns()
testQuestionGlobsAndQualifiers()
testFirstMatch()
