## This plugin uses information from the config file to set metadata
## keys.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import algorithm, ../config, ../chalkjson

type
  ToolPlugin* = ref object of Plugin
  PIInfo      = ref object
    name: string
    obj: ToolInfo

template broken(cb: CallbackObj, info: PIInfo) =
  error("missing implementation of " & $(cb) & " for tool: " & info.name)
  return false

proc runOneTool(info: PIInfo, path: string, dict: var ChalkDict): bool =
  var
    args   = @[pack(path)]
    locbox = runCallback(info.obj.getToolLocation, args)

  if locBox.isNone(): broken(info.obj.getToolLocation, info)
  var
    path   = unpack[string](locBox.get()).strip()

  if path == "":
    let installed = runCallback(info.obj.attemptInstall, args)
    if installed.isNone(): broken(info.obj.attemptInstall, info)
    if not unpack[bool](installed.get()): return false
    locbox = runCallback(info.obj.getToolLocation, args)
    if locBox.isNone(): broken(info.obj.getToolLocation, info)
    path = unpack[string](locBox.get()).strip()

  let argv = runCallback(info.obj.getCommandArgs, args)
  if argv.isNone(): broken(info.obj.getCommandArgs, info)
  let
    cmd    = pack(path & " " & unpack[string](argv.get()).strip())
    outs   = unpack[seq[Box]](c4mSystem(@[cmd]).get())

  let
    retOpt = runCallback(info.obj.produceKeys, outs)
  if retOpt.isNone(): broken(info.obj.produceKeys, info)
  let
    d   = unpack[ChalkDict](retOpt.get())

  if len(d) == 0: return false
  if d.contains("error"):
    error(unpack[string](d["error"]))
    return false
  if d.contains("warn"):
    warn(unpack[string](d["warn"]))
    d.del("warn")
  if d.contains("info"):
    warn(unpack[string](d["info"]))
    d.del("info")

  # The ChalkDict returned is of the form: chalkKey: chalkContents.
  # For instance, it might come back SBOM : "{arbitrary sbom as a
  # string}" If the string we get back parses as valid JSON, we will
  # expand it out.  If not, we use it as-is.
  #
  # These k/v pairs will be merged into the dict field, which will take
  # the form, SBOM : { info.name : chalkContents }
  #
  # Where the ChalkContents is either a JSON object or a string
  # literal.

  for k, v in d:
    var kindChalkDict: ChalkDict
    if k in dict:
      kindChalkDict = unpack[ChalkDict](dict[k])
    else:
      kindChalkDict = ChalkDict()

    kindChalkDict[info.name] = v
    for k, v in kindChalkDict:
      try:
        # Attempt to parse as a JSON object.  If not, treat it as a string,
        # but encode it into a JSON object.
        let
          asJson = parseJson(unpack[string](v))
          asBox  = asJson.nimJsonToBox()
        kindChalkDict[k] = asBox
      except:
        kindChalkDict[k] = pack[string](escapeJson(unpack[string](v)))

    dict[k] = pack(kindChalkDict)

  return info.obj.stopOnSuccess

template toolBase(s: untyped, hostScope: static[bool]) {.dirty.} =
  result = ChalkDict()

  var
    toolInfo: Table[string, seq[(int, PIInfo)]]
    dict:     ChalkDict = ChalkDict()
  let
    runSbom = chalkConfig.getRunSbomTools()
    runSast = chalkConfig.getRunSastTools()

  for k, v in chalkConfig.tools:
    if not v.enabled or hostScope != v.runs_once: continue
    if not runSbom and v.kind == "sbom":          continue
    if not runSast and v.kind == "sast":          continue
    let priority = v.priority
    if v.kind notin toolInfo:
      toolInfo[v.kind] =  @[(priority, PIInfo(name: k, obj: v))]
    else:
      toolInfo[v.kind].add((priority, PIInfo(name: k, obj: v)))

  for k, v in toolInfo:
    var sortArr = v
    sortArr.sort()
    for (ignore, info) in sortArr:
      trace("Running tool: " & info.name)
      if info.runOneTool(resolvePath(s), dict): break

  return dict

method getChalkTimeHostInfo*(self: ToolPlugin, path: seq[string]): ChalkDict =
  toolBase(path[0], true)

method getChalkTimeArtifactInfo*(self: ToolPlugin, obj: ChalkObj): ChalkDict =
 toolbase(obj.fullpath, false)

registerPlugin("tool", ToolPlugin())
