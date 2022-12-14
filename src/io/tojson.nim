import ../resources
import ../types
import ../config

import con4m

import std/json
import strutils
import tables
import strformat

proc valToJson(self: Box): string
proc foundToJson*(self: SamiDict): string

proc samiJsonEscape(self: string): string =
  samiJsonEscapeSequence & self

proc strValToJson(self: string): string =
  # The first character of a string denotes the type, which can be a
  # string or binary (which ends up hex encoded).  If it's x, or X
  # it's hex, and anything else is a string.  However, if the string
  # starts with an x, we 'escape' it by prepending a single quote,
  # which means we also need to escape strings starting with a single
  # quote.
  let s = if self[0] in jsonNeedsEscape: self.samiJsonEscape() else: self

  # %* from the json module; this basically does any escaping
  # we need, which gives us a JsonNode object, that we then convert
  # back to a string, with necessary quotes intact.
  return $( %* s)

# Keys don't allow binary, so this version does no escaping, and is
# only applied to bject keys.
proc strKeyToJson*(self: string): string =
  return $( %* self)

proc objValToJson(self: SamiDict): string =
  var comma: string

  for k, v in self:
    let
      keyJson = strKeyToJson(k)
      valJson = valToJson(v)
    result = result & kvPairJFmt.fmt()
    comma = comfyItemSep

  result = jsonObjFmt % [result]

proc arrValToJson(arr: seq[Box]): string =
  var addComma = false

  for k, v in arr:
    if addComma:
      result = result & comfyItemSep
    else:
      addComma = true
    result = result & valToJson(v)

  result = jsonArrFmt % [result]

proc valToJson(self: Box): string =
  case self.kind
  of TypeBool: return $(unbox[bool](self))
  of TypeInt: return $(unbox[uint64](self))
  of TypeString:
    return strValToJson(unbox[string](self))
  of TypeList:
    return arrValToJson(unboxList[Box](self))
  of TypeDict:
    return objValToJson(unboxDict[string, Box](self))
  else:
    unreachable

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
      keyJson = strKeyToJson(outputKey)
      valJson = valToJson(self[fullKey])

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
      keyJson = strKeyToJson(outputKey)
      valJson = valToJson(sami.newFields[fullKey])

    result = result & kvPairJFmt.fmt()
    comma = comfyItemSep

  result = jSonObjFmt % [result]
