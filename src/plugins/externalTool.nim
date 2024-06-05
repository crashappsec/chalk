##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin uses information from the config file to set metadata
## keys.

import std/[algorithm, sequtils]
import ".."/[config, plugin_api, util]

type PIInfo = ref object
  name: string
  obj:  ToolInfo

proc ensureRunCallback[T](cb: CallbackObj, args: seq[Box]): T =
  let value = runCallback(cb, args)
  if value.isNone():
    raise newException(ValueError, "missing implemenetation of " & $(cb))
  return unpack[T](value.get())

var toolCache = initTable[string, ChalkDict]()
proc runOneTool(info: PIInfo, path: string): ChalkDict =
  let key = info.name & ":" & path
  if key in toolCache:
    return toolCache[key]

  trace("Running tool: " & info.name)
  result = ChalkDict()
  let args = @[pack(path)]
  var exe  = ensureRunCallback[string](info.obj.getToolLocation, args)

  if exe == "":
    let installed = ensureRunCallback[bool](info.obj.attemptInstall, args)
    if not installed:
      trace(info.name & ": could not be installed. skipping")
      return
    exe = ensureRunCallback[string](info.obj.getToolLocation, args)

  if exe == "":
    trace(info.name & ": could not be found. skipping")
    return

  let
    argv = ensureRunCallback[string](info.obj.getCommandArgs, args)
    cmd  = exe & " " & argv.strip()
  trace(cmd)
  let
    outs = unpack[seq[Box]](c4mSystem(@[pack(cmd)]).get())

  let d = ensureRunCallback[ChalkDict](info.obj.produceKeys, outs)
  if len(d) == 0:
    trace(info.name & ": produced no keys. skipping")
    return
  if d.contains("error"):
    error(info.name & ": " & unpack[string](d["error"]))
    return
  if d.contains("warn"):
    warn(info.name & ": " & unpack[string](d["warn"]))
    d.del("warn")
  if d.contains("info"):
    info(info.name & ": " & unpack[string](d["info"]))
    d.del("info")

  trace(info.name & ": produced keys " & $(d.keys().toSeq()))
  toolCache[key] = d
  return d

template toolBase(path: string) {.dirty.} =
  result = ChalkDict()

  var
    toolInfo = initTable[string, seq[(int, PIInfo)]]()
  let
    runSbom  = get[bool](chalkConfig, "run_sbom_tools")
    runSast  = get[bool](chalkConfig, "run_sast_tools")

  # tools should only run during insert operations
  # note this is a subset of chalkable operations
  if getCommandName() notin @["build", "insert"]:
    return result

  for k, v in chalkConfig.tools:
    if not v.enabled:                    continue
    if not runSbom and v.kind == "sbom": continue
    if not runSast and v.kind == "sast": continue

    let tool = (v.priority, PIInfo(name: k, obj: v))
    if v.kind notin toolInfo:
      toolInfo[v.kind] = @[tool]
    else:
      toolInfo[v.kind].add(tool)

  for k, v in toolInfo:
    for (ignore, info) in v.sorted():
      try:
        let data = info.runOneTool(path)
        # merge multiple tools into a single structure
        # for example first tool returns:
        # { SBOM: { foo: {...} } }
        # and second tool returns:
        # { SBOM: { bar: {...} } }
        # merged structure should be:
        # { SBOM: { foo: {...}, bar: {...} } }
        result.merge(data.nestWith(info.name))
        if len(data) >= 0 and info.obj.stopOnSuccess:
          break
      except:
        error(info.name & ": " & getCurrentExceptionMsg())

proc toolGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  toolBase(resolvePath(getContextDirectories()[0]))

proc toolGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                 ChalkDict {.cdecl.} =
  if obj.fsRef != "":
    toolbase(resolvePath(obj.fsRef))
  elif getCommandName() == "build":
    toolbase(resolvePath(getContextDirectories()[0]))
  else:
    toolbase(resolvePath(obj.name))

proc loadExternalTool*() =
  newPlugin("tool",
            ctHostCallback = ChalkTimeHostCb(toolGetChalkTimeHostInfo),
            ctArtCallback  = ChalkTimeArtifactCb(toolGetChalkTimeArtifactInfo))
