## Core JSON parsing library; we couldn't use the default NIM library
## because it requires we know up front where the end of our input
## is. But we don't know as there is no length encoded; we only find
## out when we reach the end of the top-level object.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import strformat, tables, streams, unicode, parseutils, nimutils

const
  jsonWSChars      = ['\x20', '\x0a', '\x0d', '\x09']
  fmtReadTrace     = "read: {$c}; position now: {$s.getPosition()}"
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
  eBadObjMember    = "Invalid JSON obj, expected , or }}, got: '{$c}'"
  eBadObject       = "Bad object, expected either } or a string key"
  eBadElementStart = "Bad JSon at position: {s.getPosition()}"


type
  JsonNode*     = ref JsonNodeObj
  JSonError*    = ref object of ValueError
  JsonNodeKind* = enum JNull, JBool, JInt, JFloat, JString, JObject, JArray

  JsonNodeObj* {.acyclic.} = object
    case kind*: JsonNodeKind
    of JNull:   nil
    of JBool:   boolval*:  bool
    of JInt:    intval*:   int64
    of JFloat:  floatval*: float
    of JString: strval*:   string
    of JObject: kvpairs*:  OrderedTableRef[string, JsonNode]
    of JArray:  items*:    seq[JSonNode]

proc jsonNodeToBox*(n: JSonNode): Box =
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
proc jsonValue(s: Stream): JSonNode

template literalCheck(s: Stream, lit: static string) =
  const msg: string = eBadLiteral & lit

  for i in 1 .. (len(lit) - 1):
    if s.readChar() != lit[i]: raise parseError(msg)

let
  jNullLit: JsonNode = JsonNode(kind: JNull)
  jFalse: JSonNode = JsonNode(kind: JBool, boolval: false)
  jTrue: JsonNode = JsonNode(kind: JBool, boolval: true)

proc jSonNull(s: Stream): JsonNode =
  literalCheck(s, jNullStr)
  return jNullLit

proc jSonFalse(s: Stream): JsonNode =
  literalCheck(s, jFalseStr)
  return jFalse

proc jSonTrue(s: Stream): JsonNode =
  literalCheck(s, jTrueStr)
  return jTrue

# Instead of combining the sign, significand and exponent ourselves,
# we just copy into a buffer and validate, then let nim do the actual
# conversion into the IEEE floating point format.
# TODO: Got to deal w/ overflow issues better.
proc jsonNumber(s: Stream): JsonNode =
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
        return JsonNode(kind: JInt, intval: cast[int64](b))
  of 'E', 'e':
    buf.add(s.readOne())
  else:
    var b: BiggestUInt
    discard parseBiggestUInt(buf, b)
    return JsonNode(kind: JInt, intval: cast[int64](b))

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
  return JSonNode(kind: JFloat, floatval: f)

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

proc jsonString(s: Stream): JSonNode =
  result = JSonNode(kind: JString, strval: s.jsonStringRaw())

proc jsonArray(s: Stream): JSonNode =
  discard s.readOne()
  s.jsonWS()
  result = JSonNode(kind: JArray)
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

proc jsonMembers(s: Stream): OrderedTableRef[string, JsonNode] =
  result = newOrderedTable[string, JsonNode]()

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
    else: raise parseError(eBadObjMember.fmt())

proc jsonObject(s: Stream): JSonNode =
  discard s.readOne()
  s.jsonWS()
  case s.peekOne()
  of '}':
    discard s.readOne()
    return JsonNode(kind: JObject)
  of '"': return JSonNode(kind: JObject, kvpairs: s.jsonMembers())
  else:   raise parseError(eBadObject)

proc jsonValue(s: Stream): JSonNode =
  case s.peekOne()
  of '{':           return s.jsonObject()
  of '[':           return s.jsonArray()
  of '"':           return s.jsonString()
  of '0'..'9', '-': return s.jsonNumber()
  of 't':           return s.jsonTrue()
  of 'f':           return s.jsonFalse()
  of 'n':           return s.jsonNull()
  else:
    raise parseError(eBadElementStart.fmt())

proc parseJson*(s: Stream): JSonNode =
  s.jsonWS()
  result = s.jSonValue()
  # Per tho spec, we should advance the stream white space after the
  # extracted value.  However, we don't do this at the top level just
  # in case any space after the end of the element has semantic value
  # of some sort.
