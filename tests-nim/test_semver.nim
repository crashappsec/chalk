import ../src/semver

proc main() =
  assert($(parseVersion("0.1")) == "0.1")
  assert($(parseVersion("0.1-dev")) == "0.1-dev")
  assert($(parseVersion("0.1.0")) == "0.1.0")
  assert($(parseVersion("0.1.0-dev")) == "0.1.0-dev")

  assert(parseVersion("0.1") == parseVersion("0.1.0"))
  assert(parseVersion("0.1.0") == parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") == parseVersion("0.1.5")))
  assert(not(parseVersion("0.1") == parseVersion("0.1-dev")))
  assert(not(parseVersion("0.1.0") == parseVersion("0.1.5")))

  assert(parseVersion("0.1") != parseVersion("0.1.5"))
  assert(parseVersion("0.1") != parseVersion("0.1-dev"))
  assert(parseVersion("0.1.0") != parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") != parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") != parseVersion("0.1")))

  assert(parseVersion("0.1-dev") < parseVersion("0.1"))
  assert(parseVersion("0.1") < parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") < parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") < parseVersion("0.1")))
  assert(not(parseVersion("0.1") < parseVersion("0.1.0")))

  assert(parseVersion("0.1-dev") <= parseVersion("0.1"))
  assert(parseVersion("0.1") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1") <= parseVersion("0.1"))
  assert(parseVersion("0.1") <= parseVersion("0.1.0"))

  assert(parseVersion("0.1") > parseVersion("0.1-dev"))
  assert(parseVersion("0.1.5") > parseVersion("0.1"))
  assert(parseVersion("0.1.5") > parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") > parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") > parseVersion("0.1")))

  assert(parseVersion("0.1") >= parseVersion("0.1-dev"))
  assert(parseVersion("0.1.5") >= parseVersion("0.1"))
  assert(parseVersion("0.1.5") >= parseVersion("0.1.0"))
  assert(parseVersion("0.1") >= parseVersion("0.1"))
  assert(parseVersion("0.1.0") >= parseVersion("0.1"))

static:
  main()
main()
