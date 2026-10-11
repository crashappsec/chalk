import ../../src/policy/version

proc v(s: string): PackageVersion =
  parsePackageVersion(s)

proc testOrder() =
  doAssert v("1.2") == v("1.2.0")
  doAssert v("4.0.0.0") == v("4")
  doAssert v("v1.6.0") == v("1.6.0")
  doAssert v("1.2.3.4") > v("1.2.3")
  doAssert v("1.2.3.4") < v("1.2.4")
  doAssert v("1.10.0") > v("1.9.0")
  # https://semver.org/#spec-item-11
  doAssert v("1.0.0-alpha") < v("1.0.0-alpha.1")
  doAssert v("1.0.0-alpha.1") < v("1.0.0-alpha.beta")
  doAssert v("1.0.0-alpha.beta") < v("1.0.0-beta")
  doAssert v("1.0.0-beta.2") < v("1.0.0-beta.11")
  doAssert v("1.0.0-rc.9") < v("1.0.0-rc.10")
  doAssert v("1.0.0-rc.1") < v("1.0.0")
  doAssert v("1.0.0-99999999999999999999") > v("1.0.0-2")
  # build metadata does not affect precedence
  doAssert v("1.0.0+build.5") == v("1.0.0")
  doAssert v("v2.0.0+incompatible") == v("2.0.0")
  doAssert v("2.0.0+incompatible") > v("2.0.0-rc.1")
  doAssert v("1.0.0-rc.1+build") == v("1.0.0-rc.1")

proc testUnsupported() =
  for bad in ["", "abc", "1:2.36-9", "1.0.post1", "1.2.3.RELEASE", "2.0rc1",
              "1..2", "1.0-", "1.0-a..b", "^1.2", "~1.2", "99999999999999999999"]:
    try:
      discard v(bad)
      doAssert false, "accepted " & bad
    except ValueError:
      discard

testOrder()
testUnsupported()
