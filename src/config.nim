##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Wrappers for more abstracted accessing of configuration information

from pkg/con4m import get, getOpt
import "."/[run_management, config_version]
export run_management

proc selfChalkGetKey*(keyName: string): Option[Box] =
  if selfChalk == nil or selfChalk.extract == nil or
     keyName notin selfChalk.extract:
    return none(Box)
  else:
    return some(selfChalk.extract[keyName])

proc selfChalkSetKey*(keyName: string, val: Box) =
  if selfChalk.extract != nil:
    # Overwrite what we extracted, as it'll get "preserved" when
    # writing out the chalk file.
    selfChalk.extract[keyName] = val
  selfChalk.collectedData[keyName] = val

proc selfChalkDelKey*(keyName: string) =
  if selfChalk.extract != nil and keyName in selfChalk.extract:
     selfChalk.extract.del(keyName)
  if keyName in selfChalk.collectedData:
    selfChalk.collectedData.del(keyName)

proc selfChalkGetSubKey*(key: string, subKey: string): Option[Box] =
  var valueOpt = selfChalkGetKey(key)
  if valueOpt.isNone():
    valueOpt = some(pack(ChalkDict()))
  let value = unpack[ChalkDict](valueOpt.get())
  if subKey notin value:
    return none(Box)
  return some(value[subKey])

proc selfChalkSetSubKey*(key: string, subKey: string, subValue: Box) =
  var valueOpt = selfChalkGetKey(key)
  if valueOpt.isNone():
    valueOpt = some(pack(ChalkDict()))
  let value = unpack[ChalkDict](valueOpt.get())
  value[subKey] = subValue
  selfChalkSetKey(key, pack(value))

proc filterByTemplate*(dict: ChalkDict, p: MarkTemplate | ReportTemplate): ChalkDict =
  result = ChalkDict()
  for k, v in dict:
    if k in p.keys and p.keys[k].use:
      result[k] = v

proc getOutputConfig*(): OutputConfig =
  return chalkConfig.outputConfigs[getBaseCommandName()]

template getMarkTemplate*(): MarkTemplate =
  let
    outconf  = chalkConfig.outputConfigs[getBaseCommandName()]
    tmplName = outconf.mark_template

  chalkConfig.markTemplates[tmplName]

template getReportTemplate*(): ReportTemplate =
  let
    outconf  = chalkConfig.outputConfigs[getBaseCommandName()]
    tmplName = outconf.report_template

  chalkConfig.reportTemplates[tmplName]

template forceReportKeys*(keynames: openarray[string]) =
  let templateRef = getReportTemplate()

  for item in keynames:
    if item in templateRef.keys:
      templateRef.keys[item].use = true
    else:
      templateRef.keys[item] = KeyConfig(use: true)

template forceChalkKeys*(keynames: openarray[string]) =
  if isChalkingOp():
    let
      templateRef = getMarkTemplate()

    for item in keynames:
      if item in templateRef.keys:
        templateRef.keys[item].use = true
      else:
        templateRef.keys[item] = KeyConfig(use: true)

proc runCallback*(cb: CallbackObj, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.sCall(cb, args)
proc runCallback*(s: string, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.scall(s, args)

proc getChalkExeVersion*(): string =
  const version = getChalkVersion()
  version

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

proc getPluginConfig*(name: string): Option[AttrScope] =
  for k, v in getChalkSubsections("plugin"):
    if k == name:
      return some(v)

var autoHelp*:       string = ""
proc getAutoHelp*(): string = autoHelp
