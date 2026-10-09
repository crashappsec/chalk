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
## enable rules reading the same output.

import std/[
  algorithm,
  json,
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

  ## Runs the tools of `request` on `dir`, raising `ValueError` when none
  ## produced the key. Replaced by unit tests.
  PolicyToolRunner* = proc(request: ToolRequest, dir: string): seq[ToolOutput]

const maxContextDirs* = 8

proc enabledTools(kind: string): seq[string] =
  ## by priority, as `run_*_tools` orders them
  var tools: seq[(int, string)]
  for name in getChalkSubsections("tool"):
    let base = "tool." & name
    if attrGet[bool](base & ".enabled") and attrGet[string](base & ".kind") == kind:
      tools.add((attrGet[int](base & ".priority"), name))
  for (_, name) in tools.sorted():
    result.add(name)

proc runTools(request: ToolRequest, dir: string): seq[ToolOutput] =
  let tools = enabledTools(request.kind)
  if len(tools) == 0:
    raise newException(ValueError, "no " & request.kind & " tool is enabled")
  var failures: seq[string]
  for tool in tools:
    try:
      # force: chalk's own run may have scanned another directory already
      let keys = runTool(tool, dir, force = true)
      if request.key notin keys:
        failures.add(tool & " produced no " & request.key)
        continue
      result.add(ToolOutput(tool: tool, root: dir,
                            value: parseJson(keys[request.key].boxToJson())))
      if request.firstOnly or attrGet[bool]("tool." & tool & ".stop_on_success"):
        return
    except CatchableError:
      failures.add(tool & ": " & getCurrentExceptionMsg())
  if len(result) == 0:
    raise newException(ValueError, failures.join("; ") & " (see the chalk logs)")

var
  policyToolRunner*: PolicyToolRunner = runTools
  scanned = initTable[string, tuple[outputs: seq[ToolOutput], error: string]]()

proc clearPolicyToolCache*() =
  scanned.clear()

proc scanDir(request: ToolRequest, dir: string): tuple[outputs: seq[ToolOutput], error: string] =
  let key = request.kind & "\0" & request.key & "\0" & $request.firstOnly & "\0" & dir
  if key notin scanned:
    try:
      scanned[key] = (policyToolRunner(request, dir), "")
    except CatchableError:
      scanned[key] = (@[], getCurrentExceptionMsg())
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
  let tools = parseJson(dict[key].boxToJson())
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
  ## Tool output recorded in the chalk marks of the pushed images. Images
  ## without it are skipped: default chalk marks do not record it, and the
  ## build context is gone.
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
  ## Per build context directory, the `host` output (see `toolOutputs`) of
  ## the tools that scanned a directory containing it, else the output of
  ## running the tools on it on demand. Rules filter the output to the
  ## directory, as chalk scans the whole repository of a monorepo.
  if len(input.contextDirs) == 0:
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
      let (outputs, error) = request.scanDir(dir)
      if error != "":
        result.errors.add(newSubjectFinding(request.rule, "error", dir,
                                            "could not produce " & request.what &
                                            " of the build context: " & error))
        continue
      context.outputs = outputs
    result.contexts.add(context)
