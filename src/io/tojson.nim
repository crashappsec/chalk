import ../resources
import ../config

import nimutils/box

import std/json
import strutils
import tables
import strformat

proc foundToJson*(self: SamiDict): string

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

proc createdToJson*(sami: SamiObj, ptrOnly = false): string =
  var comma = ""

  for fullKey in getOrderedKeys():
    var outputKey = fullKey

    if "." in fullKey:
      let parts = fullKey.split(".")
      if len(parts) != 2 or parts[1] != "json":
        continue
      outputKey = parts[0]

    # If this key is set, but ptrOnly is false, then we are
    # outputting the "full" SAMI, in which case we do not
    # write this field out.
    if outputKey == "SAMI_PTR" and not ptrOnly:
      continue

    let spec = getKeySpec(fullKey).get()

    if not sami.newFields.contains(fullKey):
      continue

    # Skip outputting this key if "skip" is set in the key's existing
    # configuration.
    if spec.getSkip():
      continue

    # If SAMI pointers are set up, and we're currently outputting
    # a pointer, then we only output if the config has the in_ref
    # field set.
    if ptrOnly and not spec.getInRef():
      continue

    let
      keyJson = strValToJson(outputKey)
      valJson = boxToJson(sami.newFields[fullKey])

    result = result & kvPairJFmt.fmt()
    comma = comfyItemSep

  result = jSonObjFmt % [result]
