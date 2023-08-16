## Wrappers for more abstracted accessing of configuration information
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.
#

import run_management
export run_management
from macros import parseStmt

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

proc getOutputConfig*(): OutputConfig =
  return chalkConfig.outputConfigs[getBaseCommandName()]

template baseForceKeys(keynames: openarray[string], reportSym: untyped) =
  let
    reportName = getOutputConfig().reportSym
    profile    = chalkConfig.profiles[reportName]

  for item in keynames:
    if item in profile.keys:
      profile.keys[item].report = true
    else:
      profile.keys[item] = KeyConfig(report: true)

template forceHostKeys*(keynames: openarray[string]) =
  baseForceKeys(keynames, host_report)

template forceArtifactKeys*(keynames: openarray[string]) =
  baseForceKeys(keynames, artifact_report)

template forceChalkKeys*(keynames: openarray[string]) =
  baseForceKeys(keynames, chalk)

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
