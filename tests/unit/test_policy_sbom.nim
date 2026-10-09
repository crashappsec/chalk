import std/[json, os, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/policy/sbom
import ../../src/policy/tools

let fixtures = currentSourcePath().parentDir() / "fixtures"

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc fixture(name: string): JsonNode =
  parseJson(readFile(fixtures / ("sbom_" & name & ".json")))

proc sbomKey(doc: JsonNode): Box =
  nimJsonToBox(%*{"syft": doc})

proc names(sbom: Sbom): seq[string] =
  for pkg in sbom.packages:
    result.add(pkg.name)

proc testPurls() =
  assertEq(purlType("pkg:golang/github.com/google/uuid@v1.6.0"), "golang")
  assertEq(purlType("PKG:PyPI/x@1"), "pypi")
  assertEq(purlType("not-a-purl"), "")

proc testCycloneDx() =
  let doc = parseSbom(fixture("cyclonedx"))
  assertEq(doc.source, "/src")
  # file components and the scanned directory are not packages
  assertEq(len(doc.packages), 10)
  let deb = doc.packages[0]
  assertEq(deb.purlType, "deb")
  assertEq(deb.pkgType, "deb")
  assertEq(deb.language, "")
  assertEq(deb.licenses, @["LGPL-2.1"])
  for pkg in doc.packages:
    if pkg.name == "requests":
      assertEq(pkg.language, "python")
      assertEq(pkg.purlType, "pypi")
      assertEq(pkg.location, "/py/requirements.txt")
    if pkg.name == "left-pad":
      assertEq(pkg.licenses, @["MIT OR Apache-2.0"])

  # SBOMs without syft properties get the language of well-known purl types
  let plain = parseSbom(%*{"bomFormat": "CycloneDX", "components": [
    {"type": "library", "name": "x", "purl": "pkg:cargo/x@1.0.0"},
    {"type": "library", "name": "y", "purl": "pkg:generic/y@1.0.0"},
    {"type": "library", "name": "z", "components": [
      {"type": "library", "name": "n", "purl": "pkg:gem/n@1.0.0"},
    ]},
  ]})
  assertEq(len(plain.packages), 4)
  assertEq(plain.packages[0].language, "rust")
  assertEq(plain.packages[1].language, "")
  assertEq(plain.packages[3].language, "ruby")

  let web = doc.forContext("/src", "/src/web")
  assertEq(web.source, "/src/web")
  for pkg in web.packages:
    if pkg.name == "lodash":
      assertEq(pkg.location, "package-lock.json")
  assertEq(web.names(), @["@angular/core", "event-stream", "lodash", "web"])

proc testFormats() =
  # the same packages, as syft writes them in each format
  for format in ["licenses_cyclonedx", "spdx", "syft"]:
    let sbom = parseSbom(fixture(format))
    assertEq(sbom.source, "/ctx")
    var found = false
    for pkg in sbom.packages:
      doAssert not pkg.name.startsWith("/"), format & ": " & pkg.name
      if pkg.name == "gplpkg":
        found = true
        assertEq(pkg.purl, "pkg:npm/gplpkg@1.0.0")
        assertEq(pkg.purlType, "npm")
        assertEq(pkg.language, "javascript")
        assertEq(pkg.location, "/package-lock.json")
        assertEq(pkg.licenses, @["GPL-3.0-only"])
    doAssert found, format
  # SPDX: the concluded license, else the declared one
  for pkg in parseSbom(fixture("spdx")).packages:
    if pkg.name == "github.com/pkg/errors":
      assertEq(pkg.licenses.len, 0)
    if pkg.name == "dual":
      assertEq(pkg.licenses, @["(MIT OR GPL-2.0)"])
  assertEq(parseSbom(fixture("syft")).packages[2].pkgType, "go-module")
  doAssertRaises(ValueError):
    discard parseSbom(parseJson("""{"foo": 1}"""))
  doAssertRaises(ValueError):
    discard parseSbom(newJArray())

proc testTruncated() =
  var components = newJArray()
  for i in 0 .. maxSbomPackages:
    components.add(%*{"type": "library", "name": "p", "purl": "pkg:npm/p@" & $i})
  let sbom = parseSbom(%*{"bomFormat": "CycloneDX", "components": components})
  doAssert sbom.truncated
  assertEq(len(sbom.packages), maxSbomPackages)

proc input(dirs: seq[string], host = ChalkDict()): PolicyInput =
  PolicyInput(command: "build", contextDirs: dirs, host: host)

proc testPolicySboms() =
  clearPolicyToolCache()
  let host = ChalkDict()
  host["SBOM"] = sbomKey(fixture("cyclonedx"))
  # chalk's SBOM covers the context: without EXTERNAL_TOOL_DURATION, by what
  # it says it describes
  var sboms = input(@["/src/py"], host).policySboms("r")
  assertEq(len(sboms.errors), 0)
  assertEq(len(sboms.sboms), 1)
  assertEq(sboms.sboms[0].source, "/src/py")
  assertEq(sboms.sboms[0].names(), @["colourama", "django-rest", "requests"])
  assertEq(sboms.sboms[0].packages[0].location, "requirements.txt")

  # EXTERNAL_TOOL_DURATION records what chalk scanned
  host["EXTERNAL_TOOL_DURATION"] = nimJsonToBox(%*{"syft": {"/repo": 10}})
  var scanned: seq[string]
  policyToolRunner = proc(request: ToolRequest, dir: string): seq[ToolOutput] =
    scanned.add(dir)
    if dir == "/broken":
      raise newException(ValueError, "syft failed")
    @[ToolOutput(tool: "syft", root: dir, value: fixture("licenses_cyclonedx"))]
  sboms = input(@["/repo/py", "/elsewhere", "/broken"], host).policySboms("r")
  assertEq(scanned, @["/elsewhere", "/broken"])
  assertEq(len(sboms.sboms), 2)
  assertEq(len(sboms.sboms[0].packages), 3)
  assertEq(sboms.sboms[1].source, "/elsewhere")
  assertEq(len(sboms.sboms[1].packages), 8)
  assertEq(len(sboms.errors), 1)
  assertEq(sboms.errors[0].rule, "r")
  assertEq(sboms.errors[0].subject, "/broken")
  doAssert "syft failed" in sboms.errors[0].reason
  discard input(@["/elsewhere"]).policySboms("r")
  assertEq(scanned, @["/elsewhere", "/broken"])

  sboms = input(@[]).policySboms("r")
  doAssert "no local build context" in sboms.errors[0].reason

  let bad = ChalkDict()
  bad["SBOM"] = nimJsonToBox(%*{"syft": {"foo": 1}})
  bad["EXTERNAL_TOOL_DURATION"] = nimJsonToBox(%*{"syft": {"/bad": 10}})
  sboms = input(@["/bad"], bad).policySboms("r")
  assertEq(len(sboms.sboms), 0)
  assertEq(sboms.errors[0].subject, "syft")
  doAssert sboms.errors[0].reason.startsWith("could not read the SBOM of /bad: unsupported SBOM format")

  # push reads the chalk mark, when it has an SBOM
  let mark = ChalkDict()
  mark["SBOM"] = sbomKey(fixture("cyclonedx"))
  mark["CHALK_ID"] = pack("CHALK1")
  sboms = PolicyInput(command: "push", pushMarks: @[mark, ChalkDict()]).policySboms("r")
  assertEq(len(sboms.errors), 0)
  assertEq(len(sboms.sboms), 1)
  assertEq(sboms.sboms[0].source, "CHALK1")
  # relative to the directory chalk scanned when it built the image
  assertEq(sboms.sboms[0].packages[0].location, "var/lib/dpkg/status")
  assertEq(len(sboms.sboms[0].packages), 10)
  clearPolicyToolCache()

testPurls()
testCycloneDx()
testFormats()
testTruncated()
testPolicySboms()
