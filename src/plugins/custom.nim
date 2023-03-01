## This plugin allows people do do custom metadata keys via the con4m
## callback custom_metadata.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, nimutils, streams, ../types, ../config, ../plugins
import con4m/[eval, st]

const pluginName       = "custom_metadata"
const callback1Name    = "custom_string_metadata"
const callback2Name    = "custom_int_metadata"
const callback3Name    = "custom_float_metadata"
const callback1TypeStr = "f(string, string) -> {string : string}"
const callback2TypeStr = "f(string, string) -> {string : int}"
const callback3TypeStr = "f(string, string) -> {string : float}"
let   callback1Type    = callback1TypeStr.toCon4mType()
let   callback2Type    = callback2TypeStr.toCon4mType()
let   callback3Type    = callback3TypeStr.toCon4mType()

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

type CustomMetadataPlugin* = ref object of Plugin

template processOneKeyType(cbNum: untyped, cbType: string) =
  if `optInfo cbNum`.isSome():
    let
      res  = `optInfo cbNum`.get()
      dict = unpack[TableRef[string, Box]](res)

    for k, v in dict:
      let specOpt = getKeySpec(k)

      if not specOpt.isSome():
        error("When calling " & `callback cbNum Name` &
          ": key " & k & " does not match any key spec from the configuration.")
        continue

      let spec = specOpt.get()

      if  spec.getType() != cbType:
        error("When calling " & `callback cbNum Name` &
          " for custom metadata: key '" & k & "' is of type: " &
          spec.getType() & ", but metadata provided " &
          "for that key was of type: " & cbType)
        continue
      result[k] = v

method getArtifactInfo*(self: CustomMetadataPlugin, obj: ChalkObj): ChalkDict =
  result = newTable[string, Box]()

  obj.stream.setPosition(0)

  let
    contents = obj.stream.readAll()
    args     = @[pack(obj.fullpath), pack(contents)]
    optInfo1 = ctxChalkConf.sCall(callback1Name, args, callback1Type)
    optInfo2 = ctxChalkConf.sCall(callback2Name, args, callback2Type)
    optInfo3 = ctxChalkConf.sCall(callback3Name, args, callback3Type)

  processOneKeyType(1, "string")
  processOneKeyType(2, "int")
  processOneKeyType(3, "float")

registerPlugin(pluginName, CustomMetadataPlugin())

registerCon4mCallback(callback1Name, callback1TypeStr)
registerCon4mCallback(callback2Name, callback2TypeStr)
registerCon4mCallback(callback3Name, callback3TypeStr)
