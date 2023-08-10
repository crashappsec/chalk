## Wrappers for more abstracted accessing of configuration information
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.
#

import algorithm, run_management
export run_management
from macros import parseStmt

const
  hostDefault = "host_report_other_base"
  artDefault  = "artifact_report_extract_base"

proc filterByProfile*(dict: ChalkDict, p: Profile): ChalkDict =
  result = ChalkDict()
  for k, v in dict:
    if k in p.keys and p.keys[k].report: result[k] = v

proc filterByProfile*(host, obj: ChalkDict, p: Profile): ChalkDict =
  result = ChalkDict()
  # Let obj-level clobber host-level.
  for k, v in host:
    if k in p.keys and p.keys[k].report: result[k] = v
  for k, v in obj:
    if k in p.keys and p.keys[k].report: result[k] = v

proc profileToString*(name: string): string =
  if name in ["", hostDefault, artDefault]: return ""

  result      = "profile " & name & " {\n"
  let profile = chalkConfig.profiles[name]

  for k, obj in profile.keys:
    let
      scope  = obj.getAttrScope()
      report = get[bool](scope, "report")
      order  = getOpt[int](scope, "order")

    result &= "  key." & k & ".report = " & $(report) & "\n"
    if order.isSome():
      result &= "  key." & k & ".order = " & $(order.get()) & "\n"

  result &= "}\n\n"

proc sinkConfToString*(name: string): string =
  result     = "sink_config " & name & " {\n  filters: ["
  var frepr  = seq[string](@[])
  let
    config   = chalkConfig.sinkConfs[name]
    scope    = config.getAttrScope()

  for item in config.filters: frepr.add("\"" & item & "\"")

  result &= frepr.join(", ") & "]\n"
  result &= "  sink: \"" & config.sink & "\"\n"

  # copy out the config-specific variables.
  for k, v in scope.contents:
    if k in ["enabled", "filters", "loaded", "sink"]: continue
    if v.isA(AttrScope): continue
    let val = getOpt[string](scope, k).getOrElse("")
    result &= "  " & k & ": \"" & val & "\"\n"

  result &= "}\n\n"

proc getOutputConfig*(): OutputConfig =
  return chalkConfig.outputConfigs[getBaseCommandName()]

template forceArtifactKeys*(keynames: openarray[string]) =
  let
    reportName = getOutputConfig().artifact_report
    profile    = chalkConfig.profiles[reportName]

  for item in keynames:
    if item in profile.keys:
      profile.keys[item].report = true
    else:
      profile.keys[item] = KeyConfig(report: true)

proc runCallback*(cb: CallbackObj, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.sCall(cb, args)
proc runCallback*(s: string, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.scall(s, args)

macro declareChalkExeVersion(): untyped = parseStmt("const " & versionStr)
declareChalkExeVersion()

proc getChalkExeVersion*(): string   = version
proc getChalkCommitId*(): string     = commitID
proc getChalkPlatform*(): string     = osStr & " " & archStr
proc getCommandName*(): string       = commandName
proc setCommandName*(s: string) =
  ## Used when nesting operations.  For instance, when recursively
  ## chalking Zip files, we run a 'delete' over a copy of the Zip
  ## to calculate the unchalked hash.
  commandName = s

proc getChalkRuntime*(): ConfigState      = con4mRuntime.configState
proc getValidationRuntime*(): ConfigState = con4mRuntime.validationState

proc getKeySpec*(name: string): Option[KeySpec] =
  if name in chalkConfig.keyspecs: return some(chalkConfig.keyspecs[name])

proc getPluginConfig*(name: string): Option[PluginSpec] =
  if name in chalkConfig.plugins:
    return some(chalkConfig.plugins[name])

var autoHelp*:       string = ""
proc getAutoHelp*(): string = autoHelp

var
  installedPlugins: Table[string, Plugin]
  plugins:          seq[Plugin]           = @[]
  codecs:           seq[Codec]            = @[]

proc registerPlugin*(name: string, plugin: Plugin) =
  if name in installedPlugins:
    error("Double install of plugin named: " & name)
  plugin.name            = name
  installedPlugins[name] = plugin

proc validatePlugins() =
  for name, plugin in installedPlugins:
    let maybe = getPluginConfig(name)
    if maybe.isNone():
      error("No config provided for plugin " & name & ". Plugin ignored.")
      installedPlugins.del(name)
    elif not maybe.get().getEnabled():
      trace("Plugin " & name & " is disabled via config gile.")
      installedPlugins.del(name)
    else:
      plugin.configInfo = maybe.get()
      trace("Installed plugin: " & name)

proc getPlugins*(): seq[Plugin] =
  once:
    validatePlugins()
    var preResult: seq[(int, Plugin)] = @[]
    for name, plugin in installedPlugins:
      preResult.add((plugin.configInfo.getPriority(), plugin))

    preResult.sort()
    for (_, plugin) in preResult: plugins.add(plugin)

  return plugins

proc getPluginByName*(s: string): Plugin =
  return installedPlugins[s]

proc getCodecs*(): seq[Codec] =
  once:
    for item in getPlugins():
      if item.configInfo.codec: codecs.add(Codec(item))

  return codecs
