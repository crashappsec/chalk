##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Wrappers for more abstracted accessing of configuration information

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

proc filterByTemplate*(dict: ChalkDict, p: AttrScope): ChalkDict =
  result = ChalkDict()
  for k, v in dict:
    let pKeysOpt = getObjectOpt(p, "key")
    if pKeysOpt.isSome():
      let pKeys = pKeysOpt.get()
      if getObjectOpt(pKeys, k).isSome() and get[bool](pKeys, k & ".use"):
        result[k] = v

proc getOutputConfig*(): AttrScope =
  return getObject(getChalkScope(), "outconf." & getBaseCommandName())

template getMarkTemplate*(): AttrScope =
  let
    outconf  = getOutputConfig()
    tmplName = get[string](outconf, "mark_template")

  getObject(getChalkScope(), "mark_template." & tmplName)

template getReportTemplate*(): AttrScope =
  let
    outconf  = getOutputConfig()
    tmplName = get[string](outconf, "report_template")

  getObject(getChalkScope(), "report_template." & tmplName)

template forceReportKeys*(keynames: openarray[string]) =
  let templateRef = getReportTemplate()

  # Create the "key" section if required.
  if getObjectOpt(templateRef, "key").isNone() and keynames.len > 0:
    discard attrLookup(templateRef, ["key"], ix = 0, op = vlSecDef)

  let keys = getObject(templateRef, "key")

  for item in keynames:
    # Create the item section if required.
    if item notin getContents(keys):
      discard attrLookup(keys, [item], ix = 0, op = vlSecDef)
    con4mAttrSet(keys, item & ".use", pack(true), Con4mType(kind: TypeBool))

template forceChalkKeys*(keynames: openarray[string]) =
  if isChalkingOp():
    let templateRef = getMarkTemplate()

    # Create the "key" section if required.
    if getObjectOpt(templateRef, "key").isNone() and keynames.len > 0:
      discard attrLookup(templateRef, ["key"], ix = 0, op = vlSecDef)

    let keys = getObject(templateRef, "key")

    for item in keynames:
      # Create the item section if required.
      if item notin getContents(keys):
        discard attrLookup(keys, [item], ix = 0, op = vlSecDef)
      con4mAttrSet(keys, item & ".use", pack(true), Con4mType(kind: TypeBool))

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

proc getKeySpec*(name: string): Option[AttrScope] =
  for k, v in getChalkSubsections("keyspec"):
    if name == k:
      return some(v)

proc getPluginConfig*(name: string): Option[AttrScope] =
  for k, v in getChalkSubsections("plugin"):
    if k == name:
      return some(v)

var autoHelp*:       string = ""
proc getAutoHelp*(): string = autoHelp
