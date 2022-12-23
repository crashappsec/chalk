import ../resources
import ../types
import ../config

import con4m

import std/json
import strutils
import tables
import strformat

proc foundToJson*(self: SamiDict): string

proc samiJsonEscape(self: string): string =
  samiJsonEscapeSequence & self

proc strValToJson*(s: string): string =
  # %* from the json module; this basically does any escaping
  # we need, which gives us a JsonNode object, that we then convert
  # back to a string, with necessary quotes intact.
  return $( %* s)

# This version of the function takes a SAMI dictionary object,
# and is called on any nested / embedded objects; it reads from
# the dict paramter, instead of the `newFields` item found in
# the sami object.
#
# Use the one below is for insertion.
proc foundToJson*(self: SamiDict): string =
  var comma = ""

  for fullKey in getOrderedKeys():
    var outputKey = fullKey

    if "." in fullKey:
      let parts = fullKey.split(".")
      if len(parts) != 2 or parts[1] != "json":
        continue
      outputKey = parts[0]

    if not self.contains(fullKey):
      continue

    let
      keyJson = strValToJson(outputKey)
      valJson = boxToJson(self[fullKey])

    result = result & kvPairJFmt.fmt()
    comma = comfyItemSep

  result = jSonObjFmt % [result]

proc createdToJson*(sami: SamiObj): string =
  var comma = ""

  for fullKey in getOrderedKeys():
    var outputKey = fullKey

    if "." in fullKey:
      let parts = fullKey.split(".")
      if len(parts) != 2 or parts[1] != "json":
        continue
      outputKey = parts[0]

    if not sami.newFields.contains(fullKey):
      continue

    let
      keyJson = strValToJson(outputKey)
      valJson = boxToJson(sami.newFields[fullKey])

    result = result & kvPairJFmt.fmt()
    comma = comfyItemSep

  result = jSonObjFmt % [result]
