import ../types
import ../resources
import ./json
import ../config

import con4m

import streams
import tables
import strformat

proc findJsonStart*(stream: FileStream): bool =
  var
    ch: char
    pos: int = stream.getPosition()

  #  When we get here, the stream will be positioned over the first
  #  byte of the magic. But we need to find the start of the JSON, so
  #  we scan backwards. We are looking for the pattern:
  #
  #  "[ ]*:[ ]*"CIGAM_"[ ]*{
  #
  #  At each step we check the position against the minimum # of
  #  chars we MUST see.

  # Back up just one byte.
  if pos < 10: return false
  pos = pos - 1
  stream.setPosition(pos)

  if stream.peekChar() != '"': return false

  # Now we might see white space.  Back up until we are off white
  # space, or until position is less than 9 (we won't have room
  # to finish if it is)

  while true:
    pos = pos - 1
    stream.setPosition(pos)
    ch = stream.peekChar()
    if ch != ' ':
      break
    if pos < 9: return false

  # Now ch should be the colon, and if it isn't, that's a problem.
  if ch != ':': return false

  # Another batch of possible whitespace
  while true:
    pos = pos - 1
    stream.setPosition(pos)
    ch = stream.peekChar()
    if ch != ' ':
      break
    if pos < 8: return false

  # Now ch should be the quote that ends "_MAGIC".
  if ch != '"': return false

  # Jump back 7 more chars and check the rest of the key.
  pos = pos - len(rawMagicKey)
  stream.setPosition(pos)
  if stream.peekStr(len(rawMagicKey)) != rawMagicKey:
    return false

  # One more batch of potential white space.
  while true:
    pos = pos - 1
    stream.setPosition(pos)
    ch = stream.peekChar()
    if ch != ' ':
      break
    if pos == 0: return false

  # Finally, ensure the leading {
  if ch != '{': return false

  return true

proc valueFromJson(jobj: JsonNode, fname: string): Box

proc objFromJson(jobj: JsonNode, fname: string): SamiDict =
  result = new(SamiDict)

  for key, value in jobj.kvpairs:
    if result.contains(key): # SAMI objects can't have duplicate keys.
      warn(eDupeKey.fmt(), nested = false)
      continue

    result[key] = valueFromJson(jobj = value, fname = fname)

proc arrayFromJson(jobj: JsonNode, fname: string): seq[Box] =
  result = newSeq[Box]()

  for item in jobj.items:
    result.add(valueFromJson(jobj = item, fname = fname))

proc valueFromJson(jobj: JsonNode, fname: string): Box =
  case jobj.kind
  of JNull: return
  of JBool: return box(jobj.boolval)
  of JInt:
    return box(cast[int](jobj.intval))
  of JFloat: raise newException(IOError, eNoFloat)
  of JString:
    return box(jobj.strval)
  of JObject:
    let
      o = objFromJson(jobj, fname)
    return boxDict[string, Box](o)
  of JArray:
    let
      a = arrayFromJson(jobj, fname)
      
    return boxList[Box](a)

proc extractOneSamiJson*(sami: SamiObj): SamiDict =
  var jobj: JSonNode = sami.stream.parseJson()

  let fv = valueFromJson(jobj, sami.fullpath)

  return unboxDict[string, Box](fv)
