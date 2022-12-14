# TODO: This doesn't handle the include.path mechanism yet
# TODO: Some more grace on parse errors.
#
# This doesn't actually parse ints or bool, just returns
# everything as strings.
#
# config: section*
# section: header '\n' kvpair*
# header: '[' string subsection? ']'
# subsection: ([ \t]+ '"' string '"'
# kvpair: name [ \t]+ ([\\n']?('=' string)?)*
# name: [a-zA-Z0-9-]+
# # and ; are comments.

import ../resources
import streams

type KVPair* = (string, string)
type KVPairs* = seq[KVPair]
type SecInfo* = (string, string, KVPairs)

proc ws(s: Stream) =
  while true:
    let c = s.peekChar()
    case c
    of ' ', '\t': discard s.readChar()
    else: return

proc newLine(s: Stream) =
  let c = s.readChar()
  if c != '\n':
    raise newException(ValueError, eBadGitConf)

proc comment(s: Stream) =
  while true:
    let c = s.readChar()
    case c
    of '\n', '\x00': return
    else:
      discard

# Comments aren't allowed in between the brackets
proc header(s: Stream): (string, string) =
  var sec: string
  var sub: string

  while true:
    let c = s.readChar()
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.':
      sec = sec & $c
    of ' ', '\t':
      s.ws()
      let c = s.readChar()
      case c
      of ']':
        return (sec, sub)
      of '"':
        while true:
          let c = s.readChar()
          case c
          of '\\': sub = sub & $(s.readChar())
          of '"': break
          of '\x00':
            raise newException(ValueError, eBadGitConf)
          else:
            sub = sub & $c
      else:
        raise newException(ValueError, eBadGitConf)
    of ']':
      return (sec, sub)
    else:
      raise newException(ValueError, eBadGitConf)

proc kvPair(s: Stream): KVPair =
  var
    key: string
    val: string

  s.ws()
  while true:
    let c = s.peekChar()
    case c
    of '#', ';':
      discard s.readChar()
      s.comment()
      if key == "":
        return ("", "")
    of 'a'..'z', 'A'..'Z', '0'..'9', '-':
      key = key & $s.readChar()
    of ' ', '\t':
      discard s.readChar()
      s.ws()
    of '=':
      discard s.readChar()
      break
    of '\n', '\x00':
      discard s.readChar()
      return (key, "")
    of '\\':
      discard s.readChar()
      if s.readChar() != '\n':
        raise newException(ValueError, eBadGitConf)
      s.ws()
    else:
      raise newException(ValueError, eBadGitConf)

  s.ws()

  while true:
    var inString = false
    let c = s.readChar()
    case c
    of '\n', '\x00':
      break
    of '#', ';':
      if not inString:
        s.comment()
        break
      else:
        val = val & $c
    of '\\':
      let n = s.readChar()
      case n
      of '\n':
        continue
      of '\\', '"':
        val = val & $n
      of 'n':
        val = val & "\n"
      of 't':
        val = val & "\t"
      of 'b':
        val = val & "\b"
      else:
        # Be permissive, have a heart!
        val = val & $n
    of '"':
      inString = not inString
    else:
      val = val & $c

  return (key, val)

proc kvpairs(s: Stream): KVPairs =
  result = @[]

  while true:
    s.ws()
    case s.peekChar()
    of '\x00', '[':
      return
    of '\n':
      s.newLine()
      continue
    else:
      discard
    try:
      let (k, v) = s.kvPair()
      if k != "":
        result.add((k, v))
    except:
      # For now, ignore these errors.
      # Later, scan to newline and warn.
      discard


proc section(s: Stream): SecInfo =
  var sec, sub: string

  while true:
    s.ws()
    let c = s.readChar()
    case c
    of '#', ';': s.comment()
    of ' ', '\t', '\n': continue
    of '[':
      s.ws()
      (sec, sub) = s.header()
      s.ws()
      s.newLine()
      return (sec, sub, s.kvPairs())
    of '\x00':
      return ("", "", @[])
    else:
      raise newException(ValueError, eBadGitConf)

proc parseGitConfig*(s: Stream): seq[SecInfo] =
  while true:
    let (sec, sub, pairs) = s.section()
    if sec == "":
      return
    else:
      result.add((sec, sub, pairs))

