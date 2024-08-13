import ../../src/semver

proc main() =
  doAssert $(parseVersion("0.1")) == "0.1"
  doAssert $(parseVersion("0.1-dev")) == "0.1-dev"
  doAssert $(parseVersion("0.1-dev", withSuffix = false)) == "0.1"
  doAssert $(parseVersion("0.1.0")) == "0.1.0"
  doAssert $(parseVersion("0.1.0-dev")) == "0.1.0-dev"
  doAssert $(parseVersion("0.1.0", withSuffix = false)) == "0.1.0"

  doAssert parseVersion("0.1") == parseVersion("0.1.0")
  doAssert parseVersion("0.1.0") == parseVersion("0.1.0")
  doAssert parseVersion("0.1.05") == parseVersion("0.1.5")
  doAssert not (parseVersion("0.1") == parseVersion("0.1.5"))
  doAssert not (parseVersion("0.1") == parseVersion("0.1-dev"))
  doAssert not (parseVersion("0.1.0") == parseVersion("0.1.5"))

  doAssert parseVersion("0.1") != parseVersion("0.1.5")
  doAssert parseVersion("0.1") != parseVersion("0.1-dev")
  doAssert parseVersion("0.1.0") != parseVersion("0.1.5")
  doAssert not (parseVersion("0.1") != parseVersion("0.1"))
  doAssert not (parseVersion("0.1.0") != parseVersion("0.1"))

  doAssert parseVersion("0.1-dev") < parseVersion("0.1")
  doAssert parseVersion("0.1") < parseVersion("0.1.5")
  doAssert parseVersion("0.1.0") < parseVersion("0.1.5")
  doAssert not (parseVersion("0.1") < parseVersion("0.1"))
  doAssert not (parseVersion("0.1") < parseVersion("0.1.0"))

  doAssert parseVersion("0.1-dev") <= parseVersion("0.1")
  doAssert parseVersion("0.1") <= parseVersion("0.1.5")
  doAssert parseVersion("0.1.0") <= parseVersion("0.1.5")
  doAssert parseVersion("0.1") <= parseVersion("0.1")
  doAssert parseVersion("0.1") <= parseVersion("0.1.0")

  doAssert parseVersion("0.1") > parseVersion("0.1-dev")
  doAssert parseVersion("0.1.5") > parseVersion("0.1")
  doAssert parseVersion("0.1.5") > parseVersion("0.1.0")
  doAssert parseVersion("0.1.05") > parseVersion("0.1.0")
  doAssert not (parseVersion("0.1") > parseVersion("0.1"))
  doAssert not (parseVersion("0.1.0") > parseVersion("0.1"))

  doAssert parseVersion("0.1") >= parseVersion("0.1-dev")
  doAssert parseVersion("0.1.5") >= parseVersion("0.1")
  doAssert parseVersion("0.1.5") >= parseVersion("0.1.0")
  doAssert parseVersion("0.1.05") >= parseVersion("0.1.0")
  doAssert parseVersion("0.1") >= parseVersion("0.1")
  doAssert parseVersion("0.1.0") >= parseVersion("0.1")

static:
  main()
main()
