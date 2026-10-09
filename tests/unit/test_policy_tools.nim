import std/[json, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/policy/tools

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc testPaths() =
  doAssert "/src/web".isWithin("/src")
  doAssert "/src".isWithin("/src/")
  doAssert not "/src2".isWithin("/src")
  doAssert "/anything".isWithin("/")
  # syft locations are relative to what it scanned, with a leading `/`
  assertEq(contextPath("/web/package-lock.json", "/src", "/src/web"), some("package-lock.json"))
  assertEq(contextPath("/py/requirements.txt", "/src", "/src/web"), none(string))
  assertEq(contextPath("/web/../py/x", "/src", "/src/web"), none(string))
  assertEq(contextPath("app.py", "", "/ctx"), some("app.py"))
  assertEq(contextPath("/ctx/sub/app.py", "/", "/ctx"), some("sub/app.py"))
  assertEq(contextPath("/elsewhere/app.py", "/", "/ctx"), none(string))
  assertEq(contextPath("", "/src", "/src/web"), some(""))

proc findings(kinds: openArray[string]): seq[PolicyFinding] =
  for i, kind in kinds:
    result.add(newSubjectFinding("r", kind, $i, "reason"))

proc testCapFindings() =
  let few = findings(["violation", "error"])
  assertEq(capFindings(few, "r", 2, "things"), few)
  # violations are kept first, the rest summarized
  var capped = capFindings(findings(["error", "violation", "error", "violation"]), "r", 2, "things")
  assertEq(len(capped), 3)
  assertEq(capped[0].subject, "1")
  assertEq(capped[1].subject, "3")
  assertEq(capped[2].kind, "error")
  assertEq(capped[2].subject, "r")
  assertEq(capped[2].reason, "2 more things not listed")
  capped = capFindings(findings(["violation", "violation", "violation"]), "r", 1, "things")
  assertEq(capped[^1].kind, "violation")
  assertEq(capped[^1].reason, "2 more things not listed")

proc sbomKey(source: string): Box =
  nimJsonToBox(%*{"syft": {"bomFormat": "CycloneDX", "source": source}})

proc durations(tool, path: string): Box =
  nimJsonToBox(%*{tool: {path: 1000}})

const request = ToolRequest(rule: "r", kind: "sbom", key: "SBOM", what: "an SBOM",
                            runTools: true, firstOnly: true)

proc testContextOutputs() =
  clearPolicyToolCache()
  var scanned: seq[string]
  policyToolRunner = proc(request: ToolRequest, dir: string): seq[ToolOutput] =
    scanned.add(dir)
    if dir == "/broken":
      raise newException(ValueError, "syft failed")
    @[ToolOutput(tool: "syft", root: dir, value: %*{"dir": dir})]

  let host = ChalkDict()
  host["SBOM"] = sbomKey("/src")
  host["EXTERNAL_TOOL_DURATION"] = durations("syft", "/src")
  let hostOutputs = host.toolOutputs("SBOM")
  assertEq(len(hostOutputs), 1)
  assertEq(hostOutputs[0].tool, "syft")
  assertEq(hostOutputs[0].root, "/src")

  # chalk's output covers contexts below what it scanned, others are scanned
  let input = PolicyInput(command: "build", contextDirs: @["/src/web", "/elsewhere", "/broken"])
  var outputs = input.contextToolOutputs(request, hostOutputs)
  assertEq(scanned, @["/elsewhere", "/broken"])
  assertEq(len(outputs.contexts), 2)
  assertEq(outputs.contexts[0].dir, "/src/web")
  assertEq(outputs.contexts[0].outputs[0].root, "/src")
  assertEq(outputs.contexts[1].outputs[0].root, "/elsewhere")
  assertEq(len(outputs.errors), 1)
  assertEq(outputs.errors[0].kind, "error")
  assertEq(outputs.errors[0].subject, "/broken")
  assertEq(outputs.errors[0].reason, "could not produce an SBOM of the build context: syft failed")
  # once per process, failures included
  discard input.contextToolOutputs(request, hostOutputs)
  assertEq(scanned, @["/elsewhere", "/broken"])

  # output without a known root covers nothing
  discard PolicyInput(contextDirs: @["/src"]).contextToolOutputs(
    request, @[ToolOutput(tool: "syft", value: newJObject())])
  assertEq(scanned, @["/elsewhere", "/broken", "/src"])

  var off = request
  off.runTools = false
  outputs = PolicyInput(contextDirs: @["/other"]).contextToolOutputs(off, hostOutputs)
  assertEq(outputs.errors[0].reason, "an SBOM of the build context was not collected")
  off.notCollected = "enable it"
  outputs = PolicyInput(contextDirs: @["/other"]).contextToolOutputs(off, hostOutputs)
  assertEq(outputs.errors[0].reason, "enable it")

  outputs = PolicyInput(command: "build").contextToolOutputs(request, hostOutputs)
  doAssert "no local build context" in outputs.errors[0].reason

  var many: seq[string]
  for i in 0 .. maxContextDirs:
    many.add("/src/" & $i)
  outputs = PolicyInput(contextDirs: many).contextToolOutputs(request, hostOutputs)
  assertEq(len(outputs.contexts), maxContextDirs)
  doAssert "only the first" in outputs.errors[0].reason

  let bad = ChalkDict()
  bad["SBOM"] = pack("not an object")
  doAssertRaises(ValueError):
    discard bad.toolOutputs("SBOM")
  clearPolicyToolCache()

proc testPushedOutputs() =
  let mark = ChalkDict()
  mark["SBOM"] = sbomKey("/src")
  mark["CHALK_ID"] = pack("CHALK1")
  let bad = ChalkDict()
  bad["SBOM"] = pack("not an object")
  var pushed = PolicyInput(command: "push", pushMarks: @[mark, ChalkDict(), bad]).pushedToolOutputs("r", "SBOM")
  assertEq(len(pushed.outputs), 1)
  assertEq(pushed.outputs[0].image, "CHALK1")
  assertEq(pushed.errors[0].subject, "pushed image")
  doAssert pushed.errors[0].reason.startsWith("could not read SBOM in the chalk mark")
  # the tag, when only one is pushed
  pushed = PolicyInput(command: "push", pushMarks: @[mark], pushTargets: @["app:1"]).pushedToolOutputs("r", "SBOM")
  assertEq(pushed.outputs[0].image, "app:1")

testPaths()
testCapFindings()
testContextOutputs()
testPushedOutputs()
