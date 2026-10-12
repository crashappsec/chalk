##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## External tool output (`tool.*`, e.g. syft and semgrep, see
## plugins/externalTool.nim) for policy rules, per local build context
## directory on build and from the chalk marks of pushed images on push.
##
## On build, chalk's own tool run (`run_sbom_tools`, `run_sast_tools`) scans
## the git repository containing the first build context before policies
## run. A context directory below a directory chalk scanned uses that output;
## any other is scanned on demand, once per process, as several policies may
## enable rules reading the same output. On-demand scans are stopped after
## the tool's own timeout (plus a grace period) or `policyToolTimeout`, even
## when the tool's callbacks do not bound them.

import std/[
  algorithm,
  json,
  math,
  strutils,
  tables,
]
import ".."/[
  plugins/externalTool,
  types,
]
import "."/[
  api,
  helpers,
]

export helpers

type
  ToolOutput* = object
    tool*:  string   # e.g. `syft`
    value*: JsonNode # its entry in the key, e.g. `SBOM.syft`
    ## absolute directory the tool scanned, empty when unknown
    root*:  string
    ## push: the pushed image whose chalk mark recorded the output
    image*: string

  ContextOutputs* = object
    dir*:     string # absolute build context directory
    outputs*: seq[ToolOutput]

  ToolOutputs* = object
    contexts*: seq[ContextOutputs] # build
    outputs*:  seq[ToolOutput]     # push
    errors*:   seq[PolicyFinding]

  ToolRequest* = object
    rule*: string # reports the errors
    kind*: string # `tool.*.kind`, e.g. `sbom`
    key*:  string # chalk key the tools produce, e.g. `SBOM`
    what*: string # in errors, e.g. `an SBOM`
    ## Scan contexts chalk did not, else `notCollected` is an error for them
    runTools*:     bool
    notCollected*: string
    ## Stop at the first tool that produces the key. Otherwise every enabled
    ## tool runs unless one with `stop_on_success` produced it.
    firstOnly*: bool

  ToolRun* = object
    outputs*:  seq[ToolOutput]
    ## tools that did not produce the key, e.g. `semgrep: timed out`, when
    ## the request needed them: not the ones a later tool stood in for
    ## (`firstOnly`, `stop_on_success`)
    failures*: seq[string]

  ## Runs the tools of `request` on `dir`. Raises `ValueError` when no tool
  ## can run. Replaced by unit tests.
  PolicyToolRunner* = proc(request: ToolRequest, dir: string): ToolRun

const
  maxContextDirs*    = 8
  # seconds an on-demand scan may take when the tool has no timeout setting
  policyToolTimeout* = 300
  # over the tool's own timeout, so that one stops it first
  timeoutGrace       = 60

# Tool output larger than this, as JSON, is an error rather than parsed, to
# bound the memory a policy takes. A var so unit tests can lower it.
var maxToolOutputBytes* = 128 * 1024 * 1024

proc parseToolJson(value: Box, what: string): JsonNode =
  let raw = value.boxToJson()
  if len(raw) > maxToolOutputBytes:
    raise newException(ValueError, what & " is larger than " &
                                   $(maxToolOutputBytes div (1024 * 1024)) & " MiB")
  return parseJson(raw)

proc timeoutSeconds(value: string): int =
  ## `timeout`'s duration syntax (`300`, `5m`, `1.5h`); 0 when not one
  var s = value.strip().toLowerAscii()
  var unit = 1.0
  if len(s) > 0 and s[^1] in {'s', 'm', 'h', 'd'}:
    unit = case s[^1]
           of 'm': 60.0
           of 'h': 3600.0
           of 'd': 86400.0
           else:   1.0
    s = s[0 ..< ^1]
  try:
    return max(0, int(ceil(parseFloat(s) * unit)))
  except ValueError:
    return 0

proc toolDeadline*(timeoutSetting: string): int =
  ## How long an on-demand scan may take: the tool's own timeout setting
  ## (e.g. `syft_timeout`) plus a grace period, else `policyToolTimeout`, as
  ## an empty or 0 setting means no timeout
  let own = timeoutSetting.timeoutSeconds()
  if own > 0:
    return own + timeoutGrace
  return policyToolTimeout

proc timeoutSetting(tool: string): string =
  # builtin tools name it `<tool>_timeout`, e.g. `syft_timeout`
  try:
    return attrGetOpt[string]("tool." & tool & "." & tool & "_timeout").get("")
  except CatchableError:
    return ""

proc enabledTools(kind: string): seq[string] =
  ## by priority, as `run_*_tools` orders them
  var tools: seq[(int, string)]
  for name in getChalkSubsections("tool"):
    let base = "tool." & name
    if attrGet[bool](base & ".enabled") and attrGet[string](base & ".kind") == kind:
      tools.add((attrGet[int](base & ".priority"), name))
  for (_, name) in tools.sorted():
    result.add(name)

proc runEach*(request: ToolRequest, dir: string, tools: openArray[string],
              run: proc(tool: string): ChalkDict,
              stops: proc(tool: string): bool): ToolRun =
  ## `tools` in order, until one that produced the key stops the run
  ## (`firstOnly`, else when `stops`); failures before it are then dropped,
  ## as it stands in for them
  for tool in tools:
    try:
      let keys = run(tool)
      if request.key notin keys:
        result.failures.add(tool & " produced no " & request.key & " (see the chalk logs)")
        continue
      result.outputs.add(ToolOutput(tool: tool, root: dir,
                                    value: keys[request.key].parseToolJson(tool & " output")))
      if request.firstOnly or stops(tool):
        result.failures = @[]
        return
    except CatchableError:
      result.failures.add(tool & ": " & getCurrentExceptionMsg())

proc runTools(request: ToolRequest, dir: string): ToolRun =
  let tools = enabledTools(request.kind)
  if len(tools) == 0:
    raise newException(ValueError, "no " & request.kind & " tool is enabled")
  # force: chalk's own run may have scanned `dir` already. Not recorded, so
  # a failed chalk run can still retry it for the chalk mark.
  proc run(tool: string): ChalkDict =
    runTool(tool, dir, force = true, record = false,
            deadline = toolDeadline(timeoutSetting(tool)))
  proc stops(tool: string): bool =
    attrGet[bool]("tool." & tool & ".stop_on_success")
  return request.runEach(dir, tools, run, stops)

var
  policyToolRunner*: PolicyToolRunner = runTools
  scanned = initTable[string, tuple[run: ToolRun, error: string]]()

proc clearPolicyToolCache*() =
  scanned.clear()

proc scanDir(request: ToolRequest, dir: string): tuple[run: ToolRun, error: string] =
  let key = request.kind & "\0" & request.key & "\0" & $request.firstOnly & "\0" & dir
  if key notin scanned:
    try:
      let run = policyToolRunner(request, dir)
      if len(run.outputs) > 0:
        scanned[key] = (run, "")
      elif len(run.failures) > 0:
        scanned[key] = (run, run.failures.join("; "))
      else:
        scanned[key] = (run, "no tool produced " & request.key)
    except CatchableError:
      scanned[key] = (ToolRun(), getCurrentExceptionMsg())
  return scanned[key]

proc scannedRoot(dict: ChalkDict, tool: string): string =
  ## the directory `tool` scanned, as the external tool plugin records it in
  ## `EXTERNAL_TOOL_DURATION: {<tool>: {<path>: ms}}`; empty unless exactly one
  if "EXTERNAL_TOOL_DURATION" notin dict:
    return ""
  try:
    let paths = parseJson(dict["EXTERNAL_TOOL_DURATION"].boxToJson()){tool}
    if paths != nil and paths.kind == JObject and len(paths) == 1:
      for path, _ in paths.pairs():
        return path
  except CatchableError:
    discard
  return ""

proc toolOutputs*(dict: ChalkDict, key: string, image = ""): seq[ToolOutput] =
  ## `<key>: {<tool>: <output>}` as the external tool plugin records it.
  ## Raises `ValueError` when it is not an object of tool outputs.
  if dict == nil or key notin dict:
    return
  let tools = dict[key].parseToolJson(key)
  if tools.kind != JObject:
    raise newException(ValueError, key & " is not an object of tool outputs")
  for tool, value in tools.pairs():
    result.add(ToolOutput(tool: tool, value: value, image: image,
                          root: dict.scannedRoot(tool)))

proc markName(input: PolicyInput, mark: ChalkDict): string =
  # marks are only attributable to a tag when one is pushed
  if len(input.pushTargets) == 1:
    return input.pushTargets[0]
  for key in ["CHALK_ID", "_IMAGE_ID"]:
    if key in mark:
      try:
        return unpack[string](mark[key])
      except CatchableError:
        discard
  return "pushed image"

proc pushedToolOutputs*(input: PolicyInput, rule, key: string): ToolOutputs =
  ## Tool output recorded in the chalk marks of the pushed images, covering
  ## all of what chalk scanned when it built the image (the git repository
  ## of its first build context), not filtered to the build context.
  ##
  ## Images without it are skipped, so a rule passes for them rather than
  ## reporting an error: default chalk marks do not record tool output,
  ## unchalked images have no mark, a mark may keep the key in an object
  ## store (`@<key>`), and the build context is gone, so the tools cannot run
  ## on demand. Policies that must check pushes need marks that record the
  ## key; build policies check the build context itself.
  for mark in input.pushMarks:
    if mark == nil:
      continue
    let name = input.markName(mark)
    if key notin mark:
      if ("@" & key) in mark:
        trace("policy: " & key & " of " & name & " is in an object store, not checked")
      continue
    try:
      result.outputs.add(mark.toolOutputs(key, name))
    except CatchableError:
      result.errors.add(newSubjectFinding(rule, "error", name,
                                          "could not read " & key & " in the chalk mark: " &
                                          getCurrentExceptionMsg()))

proc contextToolOutputs*(input: PolicyInput, request: ToolRequest,
                         host: seq[ToolOutput]): ToolOutputs =
  ## Build only. Per build context directory, the `host` output (see
  ## `toolOutputs`) of the tools that scanned a directory containing it,
  ## else the output of running the tools on it on demand. Rules filter the
  ## output to the directory, as chalk scans the whole repository of a
  ## monorepo.
  ##
  ## `request.rule` must be registered with `requiresContext = true`:
  ## `contextDirs` is only collected for such rules, and the engine reports
  ## `contextErrors` (contexts that are not local directories) against them.
  ##
  ## On-demand runs ignore `run_*_tools`, may install the tool (e.g. syft's
  ## installer or docker image) and take up to `maxContextDirs` x tools x the
  ## tool's timeout.
  if len(input.contextDirs) == 0:
    # contexts the engine already reported cannot be checked are not repeated
    if len(input.contextErrors) == 0:
      result.errors.add(newSubjectFinding(request.rule, "error", "",
                                          "the build has no local build context to check"))
    return
  for i, dir in input.contextDirs:
    if i >= maxContextDirs:
      result.errors.add(newSubjectFinding(request.rule, "error", "",
                                          "only the first " & $maxContextDirs &
                                          " build contexts were checked"))
      break
    var context = ContextOutputs(dir: dir)
    for output in host:
      if output.root != "" and dir.isWithin(output.root):
        context.outputs.add(output)
    if len(context.outputs) == 0:
      if not request.runTools:
        let reason = if request.notCollected != "": request.notCollected
                     else: request.what & " of the build context was not collected"
        result.errors.add(newSubjectFinding(request.rule, "error", dir, reason))
        continue
      let (run, error) = request.scanDir(dir)
      if error != "":
        result.errors.add(newSubjectFinding(request.rule, "error", dir,
                                            "could not produce " & request.what &
                                            " of the build context: " & error))
        continue
      # a tool that failed leaves what it checks unchecked, whatever the others found
      for failure in run.failures:
        result.errors.add(newSubjectFinding(request.rule, "error", dir,
                                            "could not produce " & request.what &
                                            " of the build context with every tool: " &
                                            failure))
      context.outputs = run.outputs
    result.contexts.add(context)
