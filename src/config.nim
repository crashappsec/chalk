##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Wrappers for more abstracted accessing of configuration information

import std/[
  os,
]
import "."/[
  config_version,
  types,
  utils/strings,
]

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
    if sectionExists(section):
      let ss = section & "." & k
      if sectionExists(ss) and attrGet[bool](ss & ".use"):
        result[k] = v

proc getOutputConfig(): string =
  return "outconf." & getBaseCommandName()

proc getMarkTemplate*(): string =
  var tmplName = attrGetOpt[string](getOutputConfig() & ".mark_template").get("").elseWhenEmpty("mark_default")
  return "mark_template." & tmplName

proc getReportTemplate*(spec = ""): string =
  let
    ns =
      if spec == "":
        getOutputConfig()
      else:
        spec
    tmplName = attrGetOpt[string](ns & ".report_template").get("").elseWhenEmpty("null")
  return "report_template." & tmplName

proc forceKeys(keynames: openArray[string], templateRef: string) =
  let section     = templateRef & ".key"

  # Create the "key" section if required.
  if not sectionExists(section) and keynames.len > 0:
    con4mSectionCreate(section)

  let keys = attrGetObject(section).getContents()

  for item in keynames:
    # Create the item section if required.
    if item notin keys:
      con4mSectionCreate(section & "." & item)
    con4mAttrSet(
      section & "." & item & ".use",
      pack(true),
      Con4mType(kind: TypeBool),
    )

proc forceReportKeys*(keynames: openArray[string]) =
  forceKeys(keynames, getReportTemplate())

proc forceChalkKeys*(keynames: openArray[string]) =
  forceKeys(keynames, getMarkTemplate())

proc runCallback*(cb: CallbackObj, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.sCall(cb, args)
proc runCallback*(s: string, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.sCall(s, args)

proc getChalkExeVersion*(): string =
  const version = getChalkVersion()
  version

proc getChalkExeSize*(): int =
  if chalkExeSize == 0:
    chalkExeSize = getFileInfo(getMyAppPath()).size
  return chalkExeSize

proc getChalkCommitId*(): string     = commitID
proc getChalkPlatform*(): string     = osStr & " " & archStr
proc getCommandName*(): string       = commandName
proc setCommandName*(s: string, msg = "running") =
  ## Used when nesting operations.  For instance, when recursively
  ## chalking Zip files, we run a 'delete' over a copy of the Zip
  ## to calculate the unchalked hash.
  trace("chalk: " & msg & " " & s)
  commandName = s

proc getChalkRuntime*(): ConfigState      = con4mRuntime.configState
proc getValidationRuntime*(): ConfigState = con4mRuntime.validationState

var autoHelp*:       string = ""
proc getAutoHelp*(): string = autoHelp
