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

proc filterByTemplate*(dict: ChalkDict, p: string): ChalkDict =
  result = ChalkDict()
  for k, v in dict:
    let section = p & ".key"
    if sectionExists(getChalkScope(), section):
      let ss = section & "." & k
      if sectionExists(getChalkScope(), ss) and attrGet[bool](ss & ".use"):
        result[k] = v

proc getOutputConfig*(): string =
  return "outconf." & getBaseCommandName()

template getMarkTemplate*(): string =
  let tmplName = attrGet[string](getOutputConfig() & ".mark_template")
  "mark_template." & tmplName

template getReportTemplate*(): string =
  let tmplName = attrGet[string](getOutputConfig() & ".report_template")
  "report_template." & tmplName

template forceReportKeys*(keynames: openarray[string]) =
  let templateRef = getReportTemplate()
  let section     = templateRef & ".key"

  # Create the "key" section if required.
  if not sectionExists(getChalkScope(), section) and keynames.len > 0:
    discard attrLookup(
      attrGetObject(templateRef),
      ["key"],
      ix = 0,
      op = vlSecDef,
    )

  let keys = attrGetObject(section).getContents()

  for item in keynames:
    # Create the item section if required.
    if item notin keys:
      discard attrLookup(getChalkScope(), [templateRef, "key", item], ix = 0, op = vlSecDef)
    con4mAttrSet(
      getChalkScope(),
      section & "." & item & ".use",
      pack(true),
      Con4mType(kind: TypeBool),
    )

template forceChalkKeys*(keynames: openarray[string]) =
  if isChalkingOp():
    let templateRef = getMarkTemplate()
    let section     = templateRef & ".key"

    # Create the "key" section if required.
    if not sectionExists(getChalkScope(), section) and keynames.len > 0:
      discard attrLookup(
        attrGetObject(templateRef),
        ["key"],
        ix = 0,
        op = vlSecDef,
      )

    let keys = attrGetObject(section).getContents()

    for item in keynames:
      # Create the item section if required.
      if item notin keys:
        discard attrLookup(getChalkScope(), [templateRef, "key", item], ix = 0, op = vlSecDef)
      con4mAttrSet(
        getChalkScope(),
        section & "." & item & ".use",
        pack(true),
        Con4mType(kind: TypeBool),
      )

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

var autoHelp*:       string = ""
proc getAutoHelp*(): string = autoHelp
