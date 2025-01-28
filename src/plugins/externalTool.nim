##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin uses information from the config file to set metadata
## keys.

import std/[algorithm, sequtils, sets]
import ".."/[config, plugin_api, util]

type
  AlreadyRanError = object of CatchableError
  PIInfo          = ref object
    name: string

var alreadyRan = initHashSet[string]()

proc clearCallback(self: Plugin) {.cdecl.} =
  alreadyRan = initHashSet[string]()

proc ensureRunCallback[T](cb: CallbackObj, args: seq[Box]): T =
  let value = runCallback(cb, args)
  if value.isNone():
    raise newException(ValueError, "missing implemenetation of " & $(cb))
  return unpack[T](value.get())

proc runOneTool(info: PIInfo, path: string): ChalkDict =
  let key = info.name & ":" & path
  if key in alreadyRan:
    raise newException(AlreadyRanError, "")

  trace("Running tool: " & info.name)
  result = ChalkDict()
  let args = @[pack(path)]
  let base = "tool." & info.name
  var exe  = ensureRunCallback[string](attrGet[CallbackObj](base & ".get_tool_location"), args)

  if exe == "":
    let installed = ensureRunCallback[bool](attrGet[CallbackObj](base & ".attempt_install"), args)
    if not installed:
      trace(info.name & ": could not be installed. skipping")
      return
    exe = ensureRunCallback[string](attrGet[CallbackObj](base & ".get_tool_location"), args)

  if exe == "":
    trace(info.name & ": could not be found. skipping")
    return

  let
    argv = ensureRunCallback[string](attrGet[CallbackObj](base & ".get_command_args"), args)
    cmd  = exe & " " & argv.strip()
  trace(cmd)
  let
    outs = unpack[seq[Box]](c4mSystem(@[pack(cmd)]).get())

  let d = ensureRunCallback[ChalkDict](attrGet[CallbackObj](base & ".produce_keys"), outs)
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
  alreadyRan.incl(key)
  return d

template toolBase(path: string) {.dirty.} =
  result = ChalkDict()

  var
    toolInfo = initTable[string, seq[(int, PIInfo)]]()
  let
    runSBOM  = attrGet[bool]("run_sbom_tools")
    runSAST  = attrGet[bool]("run_sast_tools")

  # tools should only run during insert operations
  # note this is a subset of chalkable operations
  if getCommandName() notin @["build", "insert"]:
    return result

  for k in getChalkSubsections("tool"):
    let v = "tool." & k
    if not attrGet[bool](v & ".enabled"): continue
    let kind = attrGet[string](v & ".kind")
    if not runSBOM and kind == "sbom": continue
    if not runSAST and kind == "sast": continue

    let tool = (attrGet[int](v & ".priority"), PIInfo(name: k))
    if kind notin toolInfo:
      toolInfo[kind] = @[tool]
    else:
      toolInfo[kind].add(tool)

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
        if len(data) >= 0 and attrGet[bool]("tool." & info.name & ".stop_on_success"):
          break
      except AlreadyRanError:
        trace(info.name & ": already ran for " & path & ". skipping")
      except:
        error(info.name & ": " & getCurrentExceptionMsg())

proc toolGetChalkTimeHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  toolBase(resolvePath(getContextDirectories()[0]))

proc toolGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                 ChalkDict {.cdecl.} =
  if obj.fsRef != "":
    toolBase(resolvePath(obj.fsRef))
  elif getCommandName() == "build":
    toolBase(resolvePath(getContextDirectories()[0]))
  else:
    toolBase(resolvePath(obj.name))

proc loadExternalTool*() =
  newPlugin("tool",
            clearCallback  = PluginClearCb(clearCallback),
            ctHostCallback = ChalkTimeHostCb(toolGetChalkTimeHostInfo),
            ctArtCallback  = ChalkTimeArtifactCb(toolGetChalkTimeArtifactInfo))
