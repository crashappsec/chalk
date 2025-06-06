import ../../src/utils/semver

proc main() =
  doAssert $(parseVersion("0.1")) == "0.1"
  doAssert $(parseVersion("0.1-dev")) == "0.1-dev"
  doAssert $(parseVersion("0.1.0")) == "0.1.0"
  doAssert $(parseVersion("0.1.0-dev")) == "0.1.0-dev"

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

  doAssert $(getVersionFromLine(
    "/bin/dockerfile-frontend " &
    "github.com/moby/buildkit/frontend/dockerfile/cmd/dockerfile-frontend " &
    "dockerfile/1.2.1-labs " &
    "bf5e780c5e125bb97942ead83ff3c20705e8e8c9"
  )) == "1.2.1-labs"
  doAssert $(getVersionFromLine(
    "github.com/docker/buildx 0.19.2 1fc5647dc281ca3c2ad5b451aeff2dce84f1dc49"
  )) == "0.19.2"
  doAssert $(getVersionFromLine(
    "Docker version 27.3.1, build ce1223035a"
  )) == "27.3.1"


static:
  main()
main()
