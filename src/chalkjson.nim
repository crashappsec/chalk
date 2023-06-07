## Core JSON parsing library; we couldn't use the default NIM library
## because it requires we know up front where the end of our input
## is. But we don't know as there is no length encoded; we only find
## out when we reach the end of the top-level object.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, streams, unicode, parseutils, std/json, config

const
  jsonWSChars      = ['\x20', '\x0a', '\x0d', '\x09']
  jNullStr         = "null"
  jTrueStr         = "true"
  jFalseStr        = "false"
  eBadLiteral      = "Invalid JSON literal. Expected: "
  eDoubleNeg       = "Double negative in JSON not allowed"
  eNoExponent      = "Exponent expected"
  eBadUniEscape    = "Invalid \\u escape in JSON"
  eBadEscape       = "Invalid JSON escape command after '\\'"
  eEOFInStr        = "End of file in string"
  eBadUTF8         = "Invalid UTF-8 in JSON string literal"
  eBadArrayItem    = "Expected comma or end of array"
  eNoColon         = "Colon expected"
  eBadObject       = "Bad object, expected either } or a string key"
  rawMagicKey      = "\"MAGIC"

type
  ChalkJsonNode*   = ref JsonNodeObj
  JSonError*       = ref object of ValueError
  JsonNodeKind     = enum JNull, JBool, JInt, JFloat, JString, JObject, JArray

  JsonNodeObj* {.acyclic.} = object
    case kind*: JsonNodeKind
    of JNull:   nil
    of JBool:   boolval*:  bool
    of JInt:    intval*:   int64
    of JFloat:  floatval*: float
    of JString: strval*:   string
    of JObject: kvpairs*:  OrderedTableRef[string, ChalkJsonNode]
    of JArray:  items*:    seq[ChalkJsonNode]

proc chalkParseJson(s: Stream): ChalkJSonNode

proc findJsonStart*(stream: FileStream): bool =
  ## Seeks the stream to the start of the JSON blob, when the stream
  ## is positioned over the start of the actual magic value.
  var
    ch: char
    pos: int = stream.getPosition()

  #  When we get here, the stream will be positioned over the first
  #  byte of the magic. But we need to find the start of the JSON, so
  #  we scan backwards. We are looking for the pattern:
  #
  #  "[ ]*:[ ]*"CIGAM"[ ]*{
  #
  #  At each step we check the position against the minimum # of
  #  chars we MUST see.

  # Back up just one byte.
  if pos < 9: return false
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
    if ch != ' ': break
    if pos < 8:   return false

  # Now ch should be the colon, and if it isn't, that's a problem.
  if ch != ':': return false

  # Another batch of possible whitespace
  while true:
    pos = pos - 1
    stream.setPosition(pos)
    ch = stream.peekChar()
    if ch != ' ': break
    if pos < 7:   return false

  # Now ch should be the quote that ends "MAGIC".
  if ch != '"': return false

  # Jump back 6 more chars and check the rest of the key.
  pos = pos - len(rawMagicKey)
  stream.setPosition(pos)
  if stream.peekStr(len(rawMagicKey)) != rawMagicKey: return false

  # One more batch of potential white space.
  while true:
    pos = pos - 1
    stream.setPosition(pos)
    ch = stream.peekChar()
    if ch != ' ': break
    if pos == 0:  return false

  # Finally, ensure the leading {
  if ch != '{': return false

  return true

proc valueFromJson(jobj: ChalkJsonNode, fname: string): Box

proc objFromJson(jobj: ChalkJsonNode, fname: string): ChalkDict =
  result = new(ChalkDict)

  for key, value in jobj.kvpairs:
    if result.contains(key): # Chalk objects can't have duplicate keys.
      warn(fname & ": Duplicate entry for chalk key '" & key & "'")
      continue

    result[key] = valueFromJson(jobj = value, fname = fname)

proc arrayFromJson(jobj: ChalkJsonNode, fname: string): seq[Box] =
  result = newSeq[Box]()

  for item in jobj.items: result.add(valueFromJson(jobj = item, fname = fname))

proc valueFromJson(jobj: ChalkJsonNode, fname: string): Box =
  case jobj.kind
  of JNull:   return
  of JBool:   return pack(jobj.boolval)
  of JInt:    return pack(jobj.intval)
  of JFloat:  raise newException(IOError, fname & ": float keys aren't valid")
  of JString: return pack(jobj.strval)
  of JObject: return pack(objFromJson(jobj, fname))
  of JArray:  return pack(arrayFromJson(jobj, fname))

proc jsonNodeToBox(n: ChalkJSonNode): Box =
  case n.kind
  of JNull:   return nil
  of JBool:   return pack(n.boolval)
  of JInt:    return pack(int(n.intval))
  of JFloat:  return pack(n.floatval)
  of JString: return pack(n.strval)
  of JArray:
    var res: seq[Box] = @[]

    for item in n.items: res.add(item.jsonNodeToBox())

    return pack[seq[Box]](res)
  of JObject:
    var res: TableRef[string, Box] = newTable[string, Box]()

    for k, v in n.kvpairs:
      let b = v.jsonNodeToBox()
      res[k] = b

    return pack(res)

proc parseError(msg: string): JsonError {.inline.} = return JsonError(msg: msg)
proc readOne(s: Stream): char {.inline.} = return s.readChar()
proc peekOne(s: Stream): char {.inline.} = return s.peekChar()
proc jsonWS(s: Stream) =
  while s.peekOne() in jsonWSChars: discard s.readChar()
proc jsonValue(s: Stream): ChalkJSonNode

template literalCheck(s: Stream, lit: static string) =
  const msg: string = eBadLiteral & lit

  for i in 1 .. (len(lit) - 1):
    if s.readChar() != lit[i]: raise parseError(msg)

let
  jNullLit: ChalkJsonNode = ChalkJsonNode(kind: JNull)
  jFalse:   ChalkJSonNode = ChalkJsonNode(kind: JBool, boolval: false)
  jTrue:    ChalkJsonNode = ChalkJsonNode(kind: JBool, boolval: true)

proc jSonNull(s: Stream): ChalkJsonNode =
  literalCheck(s, jNullStr)
  return jNullLit

proc jSonFalse(s: Stream): ChalkJsonNode =
  literalCheck(s, jFalseStr)
  return jFalse

proc jSonTrue(s: Stream): ChalkJsonNode =
  literalCheck(s, jTrueStr)
  return jTrue

# Instead of combining the sign, significand and exponent ourselves,
# we just copy into a buffer and validate, then let nim do the actual
# conversion into the IEEE floating point format.
# TODO: Got to deal w/ overflow issues better.
proc jsonNumber(s: Stream): ChalkJsonNode =
  var
    buf:    string
    gotNeg: bool
    c = s.readOne()

  case c
  of '-':
    if gotNeg:
      raise parseError(eDoubleNeg)
    gotNeg = true
    buf.add(c)
  of '0':
    buf.add(c)
  of '1' .. '9':
    buf.add(c)
    while true:
      c = s.peekOne()
      case c
      of '0' .. '9':
        buf.add(s.readOne())
      else: break
  else: unreachable

  c = s.peekOne()
  case c
  of '.':
    buf.add(s.readOne())
    while true:
      c = s.peekOne()
      case c
      of '0' .. '9':
        buf.add(s.readOne())
      of 'E', 'e':
        buf.add(s.readOne())
        break
      else:
        var b: BiggestUInt
        discard parseBiggestUInt(buf, b)
        return ChalkJsonNode(kind: JInt, intval: cast[int64](b))
  of 'E', 'e':
    buf.add(s.readOne())
  else:
    var b: BiggestUInt
    discard parseBiggestUInt(buf, b)
    return ChalkJsonNode(kind: JInt, intval: cast[int64](b))

  c = s.readOne()
  case c
  of '-', '+':
    buf.add(c)
    c = s.peekOne()
    if c < '0' or c > '9':
      raise parseError(eNoExponent)
    buf.add(s.readOne())
  of '0' .. '9':
    buf.add(s.readOne())
  else:
    raise parseError(eNoExponent)

  while true:
    c = s.peekOne()
    if c < '0' or c > '9': break
    buf.add(s.readOne())

  var f: BiggestFloat
  discard parseBiggestFloat(buf, f)
  return ChalkJSonNode(kind: JFloat, floatval: f)

when (NimMajor, NimMinor) >= (1, 7):
  {.warning[CastSizes]: off.}

proc jsonStringRaw(s: Stream): string =
  discard s.readOne()
  var str: string

  while true:
    var c = s.readOne()

    case c
    of '\\':
      c = s.readOne()
      case c
      of '"', '\\', '/': str.add(c)
      of 'b': str.add('\b')
      of 'f': str.add('\f')
      of 'n': str.add('\n')
      of 'r': str.add('\r')
      of 't': str.add('\t')
      of 'u':
        var codepoint: int32
        for _ in 0 .. 3:
          c = s.readOne()
          codepoint = codepoint shl 4
          case c
          of '0' .. '9':
            codepoint = codepoint or (cast[int32](c) - cast[int32]('0'))
          of 'a' .. 'f':
            codepoint = codepoint or (cast[int32](c) - cast[int32]('a') + 0xa)
          of 'A' .. 'F':
            codepoint = codepoint or (cast[int32](c) - cast[int32]('A') + 0xa)
          else:
            raise parseError(eBadUniEscape)
        let r: Rune = cast[Rune](codepoint)
        str.add($r)
      else: raise parseError(eBadEscape)

    of '"': break
    of '\x00': raise parseError(eEOFInStr)
    else: str.add(c)

  if str.validateUtf8() != -1: raise parseError(eBadUTF8)

  return str

proc jsonString(s: Stream): ChalkJSonNode =
  result = ChalkJsonNode(kind: JString, strval: s.jsonStringRaw())

proc jsonArray(s: Stream): ChalkJSonNode =
  discard s.readOne()
  s.jsonWS()
  result = ChalkJSonNode(kind: JArray)
  if s.peekOne() == ']':
    discard s.readOne()
    return
  while true:
    result.items.add(s.jsonValue())
    s.jsonWS()
    case s.peekOne()
    of ']':
      discard s.readOne()
      return
    of ',':
      discard s.readOne()
      s.jsonWS()
      continue
    else:
      raise parseError(eBadArrayItem)

proc jsonMembers(s: Stream): OrderedTableRef[string, ChalkJsonNode] =
  result = newOrderedTable[string, ChalkJsonNode]()

  while true:
    let k = s.jsonStringRaw()
    s.jsonWS()
    if s.readOne() != ':': raise parseError(eNoColon)
    s.jsonWS()
    let v = s.jsonValue()
    result[k] = v
    s.jsonWS()
    var c = s.readOne()
    case c
    of '}': return
    of ',': s.jsonWS()
    else:
      raise parseError("Invalid JSON obj, expected ',' or }, got: '" & $c & "'")

proc jsonObject(s: Stream): ChalkJSonNode =
  discard s.readOne()
  s.jsonWS()
  case s.peekOne()
  of '}':
    discard s.readOne()
    return ChalkJsonNode(kind: JObject)
  of '"': return ChalkJSonNode(kind: JObject, kvpairs: s.jsonMembers())
  else:   raise parseError(eBadObject)

proc jsonValue(s: Stream): ChalkJSonNode =
  case s.peekOne()
  of '{':           return s.jsonObject()
  of '[':           return s.jsonArray()
  of '"':           return s.jsonString()
  of '0'..'9', '-': return s.jsonNumber()
  of 't':           return s.jsonTrue()
  of 'f':           return s.jsonFalse()
  of 'n':           return s.jsonNull()
  else:
    raise parseError("Bad JSon at position: " & $(s.getPosition()))

proc chalkParseJson(s: Stream): ChalkJSonNode =
  s.jsonWS()
  result = s.jSonValue()
  # Per the spec, we should advance the stream white space after the
  # extracted value.  However, we don't do this at the top level just
  # in case any space after the end of the element has semantic value
  # of some sort.

proc extractOneChalkJson*(stream: Stream, path: string): ChalkDict =
  return unpack[ChalkDict](valueFromJson(stream.chalkParseJson(), path))

# %* from the json module; this basically does any escaping
# we need, which gives us a JsonNode object, that we then convert
# back to a string, with necessary quotes intact.

proc toJson*(dict: ChalkDict, profile: Profile = nil): string =
  result    = ""
  var comma = ""
  let keys = dict.orderKeys(profile)

  for fullKey in keys:
    let
      keyJson = $(%* fullKey)
      # _CHALKS key is special-cased so we don't have to keep re-sorting.
      valJson = if fullKey == "_CHALKS": unpack[string](dict[fullKey])
                else:                    boxToJson(dict[fullKey])

    result = result & comma & keyJson & " : " & valJson
    comma  = ", "

  result = "{ " & result & " }"

proc prepareContents*(dict: ChalkDict, p: Profile): string =
  return dict.filterByProfile(p).toJson(p)

proc prepareContents*(host, obj: ChalkDict, oneProfile: Profile): string =
  return host.filterByProfile(obj, oneProfile).toJson(oneProfile)

template profileEnabledCheck(profile: Profile) =
  if profile.enabled == false:
    error("FATAL: invalid to disable the chalk profile when inserting." &
          " did you mean to use the virtual chalk feature?")
    quit(1)

proc getChalkMark*(obj: ChalkObj): ChalkDict =
  let profile = chalkConfig.profiles[getOutputConfig().chalk]
  profile.profileEnabledCheck()

  return hostInfo.filterByProfile(obj.collectedData, profile)

proc getChalkMarkAsStr*(obj: ChalkObj): string =
  let profile = chalkConfig.profiles[getOutputConfig().chalk]
  profile.profileEnabledCheck()

  return hostInfo.prepareContents(obj.collectedData, profile)
