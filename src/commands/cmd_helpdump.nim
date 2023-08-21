#% INTERNAL
## The `chalk helpdump` command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import ../config

const cmdlineKeys  = ["doc", "shortdoc", "args", "aliases", "field_to_set",
                      "yes_aliases", "no_aliases", "default_no_prefixes"]
const keyspecKeys  = ["kind", "type", "doc"]
const schemaKeys   = ["type", "require", "default", "hidden", "write_lock",
                      "range", "choice", "doc", "shortdoc"]


proc docFilter(s: JsonNode, targetKeys: openarray[string]): Option[JsonNode] =
  case s.kind
  of JNull:
    return none(JsonNode)
  of JBool, JInt, JFloat, JString:
    return some(s)
  of JArray:
    var resItems: seq[JSonNode]
    for item in s.items():
      let subres = item.docFilter(targetKeys)
      if subres.isSome():
        resItems.add(subres.get())
    if len(resItems) != 0:
      var arr = newJArray()
      arr.elems = resItems
      return some(arr)
    else:
      return none(JsonNode)
  of JObject:
    var outObj = newJObject()
    for k, v in s.fields:
      if k in targetKeys:
        case v.kind
        of JNull, JBool, JInt, JFloat, JString, JArray:
          outObj[k] = v
        else:
          let subres = v.docFilter(targetKeys)
          outObj[k] = subres.getOrElse(newJNull())
      else:
        let subres = v.docFilter(targetKeys)
        if subres.isSome():
          outObj[k] = subres.get()
    if outObj.len() == 0:
      return none(JSonNode)
    else:
      return some(outObj)

proc getHelpJson(): string =
  let
    chalkRuntime  = getChalkRuntime()
    cmdlineInfo   = chalkRuntime.attrs.getObject("getopts")
    keyspecInfo   = chalkRuntime.attrs.getObject("keyspec")
    schemaInfo    = getValidationRuntime().attrs
    cmdlineJson   = cmdlineInfo.scopeToJson().parseJson().docFilter(cmdlineKeys)
    keyspecJson   = keyspecInfo.scopeToJson().parseJson().docFilter(keyspecKeys)
    schemaJson    = schemaInfo.scopeToJson().parseJson().docFilter(schemaKeys)
    builtinFns    = unpack[string](c4mFuncDocDump(@[], chalkRunTime).get())
    biFnJson      = builtinFns.parseJson()

  var
    preRes = newJObject()

  preRes["command_line"]        = cmdlineJson.get()
  preRes["key_specs"]           = keyspecJson.get()
  preRes["config_file_schema"]  = schemaJson.get()
  preRes["builtin_funs"]        = biFnJson

  result = $(preRes)

import os, json, strutils

proc runCmdHelpDump*() =
  if not chalkConfig.getChalkDebug():
    publish("help", getHelpJson())
    return

  let
    outdir             = getEnv("CHALK_DOC_DIR")
  var
    jsonStr = getHelpJson().parseJson()
    funcs   = jsonStr["builtin_funs"]
    output  = """
# Chalk Config File: Available Functions
| Function | Categories | Description |
| -------- | ---------- | ----------- |
"""

  for k, v in funcs.mpairs():
    if not to(v["builtin"], bool):
      continue
    var
      sig  = k.replace("`", "\\`").replace("->", "→")
      doc  = to(v["doc"], string).replace("\n", "<br />").
                replace("`", "\\`")
      tags = to(v["tags"], seq[string])

    output &= "| " & sig & " | " & tags.join(", ") & " | " & doc & " |\n"

  echo output

#% END
