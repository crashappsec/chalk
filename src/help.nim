## Our kind of janky help system. It basically at compile time embeds
## the src/help directory into a dictionary, so you can look up help
## topics.  The only other thing is does is some basic format
## substitution, which is definitely janky.
##
## I was originally expecting to pick a markdown variant, and to
## figure out the best approach for ANSI color formatting (which
## mostly lives in the nimutils library). But, the few existing
## markdown parsers for Nim all go STRAIGHT to html which doesn't help
## us for terminal output.  And I sure didn't want to write a full
## Markdown parser for any variant... but probably will eventually.
##
## Until then, what's here is good enough.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import unicode, tables, os, nimutils, std/terminal, defaults,  options,
       formatstr, builtins
from strutils import replace, split, find

when true:
  import formatstr
else:
  # I built this as a quick and dirty sanity check to see if
  # formatstr() is broken, or if it's some weird ansi code problem.
  # Basically, if I add "brown" in, it sometimes clobbers other
  # colors.
  #
  # Leaving it in for the time being.
  proc format(s: string, map: openarray[(string,string)]): string =
    let
      limit = s.len()
    var
      i        = 0
      curStart = 0

    result = ""

    while i < limit:
      case s[i]
      of '\\':
        i = i + 1
      of '{':
        result  &= s[curStart ..< i]
        i        = i + 1
        curstart = i
        while i < limit:
          case s[i]
          of '\\':
            i = i + 1
          of '}':
            break
          else:
            discard
          i = i + 1
        if i == limit:
          raise newException(ValueError, "Missing } in format specifier")
        else:
          let
            key = s[curStart ..< i]
          var
            found = false
            val: string

          for (k, v) in map:
            if k == key:
              val = v
              found = true
              break
          if not found:
            raise newException(ValueError, "invalid specifier: '" & key & "'")
          result &= val
          i        = i + 1
          curstart = i
      else:
        discard
      i = i + 1
    result &= s[curStart .. ^1]


const helpPath   = staticExec("pwd") & "/help/"
const helpCorpus = newOrderedFileTable(helpPath)

type
  JankKind  = enum JankText, JankTable, JankHeader, JankCodeBlock
  JankBlock = ref object
    content: string
    kind:    JankKind

proc jankyFormat(s: string): string =
  try:
    return s.format(
      {
        "nl"           : "\n",
        "appName"      : getAppFileName().splitPath().tail,
        "black"        : toAnsiCode(@[acBlack]),
        "red"          : toAnsiCode(@[acRed]),
        "green"        : toAnsiCode(@[acGreen]),
        "yellow"       : toAnsiCode(@[acYellow]),
        "blue"         : toAnsiCode(@[acBlue]),
        "magenta"      : toAnsiCode(@[acMagenta]),
        "cyan"         : toAnsiCode(@[acCyan]),
        "white"        : toAnsiCode(@[acWhite]),
        "brown"        : toAnsiCode(@[acBrown]),
        "purple"       : toAnsiCode(@[acPurple]),
        "bblack"       : toAnsiCode(@[acBBlack]),
        "bred"         : toAnsiCode(@[acBRed]),
        "bgreen"       : toAnsiCode(@[acBGreen]),
        "byellow"      : toAnsiCode(@[acBYellow]),
        "bblue"        : toAnsiCode(@[acBBlue]),
        "bmagenta"     : toAnsiCode(@[acBMagenta]),
        "bcyan"        : toAnsiCode(@[acBCyan]),
        "bwhite"       : toAnsiCode(@[acBWhite]),
        "bgblack"      : toAnsiCode(@[acBGBlack]),
        "bgred"        : toAnsiCode(@[acBGRed]),
        "bggreen"      : toAnsiCode(@[acBgGreen]),
        "bgyellow"     : toAnsiCode(@[acBGYellow]),
        "bgblue"       : toAnsiCode(@[acBGBlue]),
        "bgmagenta"    : toAnsiCode(@[acBGMagenta]),
        "bgcyan"       : toAnsiCode(@[acBGCyan]),
        "bgwhite"      : toAnsiCode(@[acBGWhite]),
        "bold"         : toAnsiCode(@[acBold]),
        "unbold"       : toAnsiCode(@[acUnbold]),
        "invert"       : toAnsiCode(@[acInvert]),
        "uninvert"     : toAnsiCode(@[acUninvert]),
        "strikethru"   : toAnsiCode(@[acStrikethru]),
        "nostrikethru" : toAnsiCode(@[acNostrikethru]),
        "font0"        : toAnsiCode(@[acFont0]),
        "font1"        : toAnsiCode(@[acFont1]),
        "font2"        : toAnsiCode(@[acFont2]),
        "font3"        : toAnsiCode(@[acFont3]),
        "font4"        : toAnsiCode(@[acFont4]),
        "font5"        : toAnsiCode(@[acFont5]),
        "font6"        : toAnsiCode(@[acFont6]),
        "font7"        : toAnsiCode(@[acFont7]),
        "font8"        : toAnsiCode(@[acFont8]),
        "font9"        : toAnsiCode(@[acFont9]),
        "reset"        : toAnsiCode(@[acReset])
    })
  except:
    # Generally we want to ignore these problems, but when
    # running a debug build, let's expose them.
    publish("debug", getCurrentException().getStackTrace())
    return s
proc parseJankText(s: string, width: int): seq[JankBlock] =
  let
    processed = s.jankyFormat()
    lines     = processed.split("\n")

  for i, line in lines:
    if line == "" and i + 1 == len(lines):
      break
    result.add(JankBlock(kind: JankText,
                         content: indentWrap(line.strip(),
                                             width,
                                             hangingIndent = 0) & "\n"))

import parseutils

template `not`(x: int): untyped = x == 0

proc parseJankTable(s: string, width: int, plain: bool): JankBlock =
  let
    strRows = s.jankyFormat().strip(leading=false).split(Rune('\n'))
  var
    rows: seq[seq[string]] = @[]
    maxCols                = 0
    options                = strRows[0].strip()


  for line in strRows[1 .. ^1]:
    var
      row = strutils.split(line, "::")
      n   = len(row)

    if n > maxCols:
      maxCols = n

    for i in 0 ..< n:
      row[i] = row[i].strip()

    rows.add(row)

  for i in 0 ..< len(rows):
    var row = rows[i]
    while len(row) < maxCols:
      row.add("")

  var t = chalkTableFormatter(maxCols,
                              rows=rows,
                              wrapStyle=WrapLines,
                              maxCellSz=0)

  if options.len != 0:
    let specs = options.split(Rune(':'))
    for i, item in specs:
      var parsed: int
      if not len(item): continue
      case item[0]
      of '>':
        discard parseInt(item[1..^1], parsed, 0)
        discard t.newColSpec(maxChr = parsed, colNum = i)
      of '<':
        discard parseInt(item[1..^1], parsed, 0)
        discard t.newColSpec(minChr = parsed, colNum = i)
      else:
          raise newException(ValueError, "Invalid janky col width specifier")

  if plain:
    t.setNoFormatting()
    t.setNoBorders()
    t.setNoHeaders()

  return JankBlock(kind: JankTable, content: t.render(width))

proc jankHeader1(s: string): JankBlock =
  let ret = toAnsiCode(@[acBCyan]) & s & toAnsiCode(@[acReset])
  return JankBlock(kind: JankHeader, content: ret.jankyFormat())

proc jankHeader2(s: string): JankBlock =
  let ret = toAnsiCode(@[acBGCyan]) & s & toAnsiCode(@[acReset])
  return JankBlock(kind: JankHeader, content: ret.jankyFormat())

proc jankCodeBlock(s: string, width: int): JankBlock =
  var
    formatted = s.jankyFormat()
    t         = chalkTableFormatter(1,
                                    @[@[formatted]],
                                    some(AlignLeft),
                                    WrapLines,
                                    0)

  return JankBlock(kind: JankCodeBlock, content: t.render(width))


proc parseJank(s: string, width: int): seq[JankBlock]

proc parseJankCtrl(s: string, width: int): seq[JankBlock] =
  var n = s[1 .. ^1]
  case s[0]
  of 't': # Table, plain, no headers or borders.
    return @[parseJankTable(n, width, true)]
  of 'T': # Table, yes headers and borders.
    return @[parseJankTable(n, width, false)]
  of 'H':
    n = n.strip()
    return @[jankHeader1(n)]
  of 'h':
    n = n.strip()
    return @[jankHeader2(n)]
  of 'i', 'I':
    n = n.strip()
    return parseJank(helpCorpus[n].strip(), width)
  of 'c':
    n = n.strip()
    return @[jankCodeBlock(n, width)]
  else:
    raise newException(ValueError, "Janky jank option: '" & $(Rune(s[0])))

proc parseJank(s: string, width: int): seq[JankBlock] =
  result = @[]
  var cur = s

  while len(cur) != 0:
    var
      nextCtrl  = cur.find("%{")
      nextBreak = cur.find("\n")

    if nextCtrl == -1:
      for line in cur.split("\n"):
        var content = line.strip()
        if len(content) == 0:
          result.add(JankBlock(kind: JankText, content: "\n"))
          continue
        result.add(parseJankText(content & "\n", width))
      return
    if nextBreak == -1: nextBreak = len(cur)

    if nextCtrl < nextBreak:
      let endDelim = cur.find("}%")
      if endDelim == -1:
        raise newException(ValueError, "Missing end delimiter for jankiness")
      result.add(parseJankCtrl(cur[2 ..< endDelim], width))
      cur = cur[(endDelim + 2) .. ^1]
    else:
      result.add(parseJankText(cur[0 .. nextBreak], width))
      cur = cur[nextBreak+1 .. ^1]

proc doHelp*() {.noreturn.} =
  var
    jank:  seq[JankBlock] = @[]
    args:  seq[string]    = getArgs()
    width                 = terminalWidth()

  if len(args) == 0:
    args = @["main"]

  for arg in args:
    if arg == "topics" or arg notin helpCorpus:
      if arg != "topics":
         jank.add(jankHeader2("No such topic: '" & arg & "\n"))
         continue

      var topics: seq[string] = @[]
      var widest              = 0

      for key, _ in helpCorpus: topics.add(key)

      for item in topics:
        if len(item) > widest:
          widest = len(item)

      let
        numCols          = max(int(terminalWidth() / (widest + 3)), 1)
        remainder        = len(topics) mod numCols
      var
        table            = newTextTable(numCols)
        row: seq[string] = @[]

      table.setNoHeaders()

      for item in topics:
        row.add(item)

        if len(row) == numCols:
          table.addRow(row)
          row = @[]

      if remainder != 0:
        for i in remainder ..< numCols:
          row.add("")
        table.addRow(row)
      jank.add(jankHeader1("Available help topics:\n"))
      jank.add(JankBlock(kind:    JankTable,
                         content: table.render(max(terminalWidth(), 2*widest))))
    else:
      var processed = arg.replace('_', ' ')
      processed = $(Rune(processed[0]).toUpper()) & processed[1 .. ^1]
      jank.add(parseJank(helpCorpus[arg].strip(), width))

  var msg = ""

  for item in jank:
    msg &= item.content

  publish("help", msg)
  quit()
