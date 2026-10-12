import std/[json, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/plugins/externalTool
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
  policyToolRunner = proc(request: ToolRequest, dir: string): ToolRun =
    scanned.add(dir)
    if dir == "/broken":
      raise newException(ValueError, "syft failed")
    if dir == "/partial":
      return ToolRun(outputs: @[ToolOutput(tool: "b", root: dir, value: %*{})],
                     failures: @["a: timed out"])
    if dir == "/none":
      return ToolRun(failures: @["a: timed out", "b produced no SBOM"])
    ToolRun(outputs: @[ToolOutput(tool: "syft", root: dir, value: %*{"dir": dir})])

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

  # a failed tool is an error even when another produced output
  outputs = PolicyInput(contextDirs: @["/partial", "/none"]).contextToolOutputs(request, hostOutputs)
  assertEq(len(outputs.contexts), 1)
  assertEq(outputs.contexts[0].outputs[0].tool, "b")
  assertEq(len(outputs.errors), 2)
  assertEq(outputs.errors[0].subject, "/partial")
  assertEq(outputs.errors[0].reason,
           "could not produce an SBOM of the build context with every tool: a: timed out")
  assertEq(outputs.errors[1].subject, "/none")
  assertEq(outputs.errors[1].reason,
           "could not produce an SBOM of the build context: a: timed out; b produced no SBOM")

  # output without a known root covers nothing
  discard PolicyInput(contextDirs: @["/src"]).contextToolOutputs(
    request, @[ToolOutput(tool: "syft", value: newJObject())])
  assertEq(scanned, @["/elsewhere", "/broken", "/partial", "/none", "/src"])

  var off = request
  off.runTools = false
  outputs = PolicyInput(contextDirs: @["/other"]).contextToolOutputs(off, hostOutputs)
  assertEq(outputs.errors[0].reason, "an SBOM of the build context was not collected")
  off.notCollected = "enable it"
  outputs = PolicyInput(contextDirs: @["/other"]).contextToolOutputs(off, hostOutputs)
  assertEq(outputs.errors[0].reason, "enable it")

  outputs = PolicyInput(command: "build").contextToolOutputs(request, hostOutputs)
  doAssert "no local build context" in outputs.errors[0].reason
  # not repeated for contexts the engine reports against the rule
  outputs = PolicyInput(command: "build", contextErrors: @[collectionError("stdin")]).contextToolOutputs(
    request, hostOutputs)
  assertEq(len(outputs.errors), 0)
  assertEq(len(outputs.contexts), 0)

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
  # too large to parse
  let saved = maxToolOutputBytes
  maxToolOutputBytes = 10
  doAssertRaises(ValueError):
    discard host.toolOutputs("SBOM")
  maxToolOutputBytes = saved
  clearPolicyToolCache()

proc testRunEach() =
  # tools that produce the key: `ok*`; others fail
  proc run(tool: string): ChalkDict =
    if tool == "raises":
      raise newException(ValueError, "timed out")
    result = ChalkDict()
    if tool.startsWith("ok"):
      result["SBOM"] = sbomKey("/" & tool)
  proc never(tool: string): bool = false
  proc stopsAtOk(tool: string): bool = tool == "ok-stop"

  var sast = request
  sast.firstOnly = false
  # every tool runs; failures stay reported next to the output
  var run1 = sast.runEach("/d", ["raises", "ok1", "empty", "ok2"], run, never)
  assertEq(len(run1.outputs), 2)
  assertEq(run1.outputs[0].root, "/d")
  assertEq(run1.failures, @["raises: timed out", "empty produced no SBOM (see the chalk logs)"])
  # a tool with stop_on_success stands in for those that failed before it
  run1 = sast.runEach("/d", ["raises", "ok-stop", "ok2"], run, stopsAtOk)
  assertEq(len(run1.outputs), 1)
  assertEq(len(run1.failures), 0)
  # firstOnly: the first output stands in for earlier failures
  run1 = request.runEach("/d", ["raises", "empty", "ok1", "ok2"], run, never)
  assertEq(len(run1.outputs), 1)
  assertEq(run1.outputs[0].tool, "ok1")
  assertEq(len(run1.failures), 0)
  run1 = request.runEach("/d", ["raises", "empty"], run, never)
  assertEq(len(run1.outputs), 0)
  assertEq(len(run1.failures), 2)

proc testDeadline() =
  assertEq(toolDeadline("300"), 360)
  assertEq(toolDeadline(" 5m "), 360)
  assertEq(toolDeadline("1.5h"), 5460)
  # no timeout of its own: the policy's
  for setting in ["", "0", "soon"]:
    assertEq(toolDeadline(setting), policyToolTimeout)
  assertEq("PATH=/x:$PATH semgrep scan . 2>/dev/null".withDeadline(60, "/usr/bin/timeout"),
           "/usr/bin/timeout -s TERM 60 /bin/sh -c 'PATH=/x:$PATH semgrep scan . 2>/dev/null'")

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
testRunEach()
testDeadline()
testPushedOutputs()
