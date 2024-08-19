## We're going to use the nimutils topic outputting system, publishing
## everything to a "con4m" topic.  By default, we'll use the nimutils
## log-level system to decide what to publish.

import tables, strutils, strformat, os, unicode, nimutils, nimutils/logging,
       types
export getOrElse

type
  InstInfo*    = tuple[filename: string, line: int, column: int]
  C4Verbosity* = enum c4vBasic, c4vShowLoc, c4vTrace, c4vMax
  Con4mError*  = object of CatchableError

let
  con4mTopic*  = registerTopic("con4m")
  `hook?`       = configSink(getSinkImplementation("stderr").get(),
                             "con4m-default",
                             filters = @[MsgFilter(logLevelFilter),
                                         MsgFilter(logPrefixFilter)])
  defaultCon4mHook* = `hook?`.get()

var
  publishParams = { "loglevel" : $(llError) }.newOrderedTable()
  verbosity     = c4vShowLoc
  curFileName: string

proc formatTb(tb, throwinfo: string): string =
  var
    nimbleDirs: OrderedTable[string, string]
    cells:      seq[seq[Rope]]
    title:      Rope
    caption:    Rope = atom(getCurrentExceptionMsg())
    pathInfo:   Rope
    row:        seq[Rope]

  let lines = strutils.split(tb, "\n")
  for i, line in lines:
    row = @[]
    if i == 0:
      title = atom(line)
      continue
    if len(line) == 0:
      continue
    let parts = line.split("/")
    if line[0] == '/' and "/.nimble/pkgs2/" in line:
      for j, item in parts:
        if item == "pkgs2":
          if parts[j+2] notin nimbleDirs:
            nimbleDirs[parts[j+2]] = parts[0 .. j+1].join("/")
            pathInfo = atom(parts[j+2 ..< ^1].join("/") & "/")
          break
    else:
      pathInfo = atom(parts[0 ..< ^1].join("/") & "/")

    let toEmph = parts[^1].split(' ')
    row.add(pathInfo + em(toEmph[0]))
    row.add(em(toEmph[1 .. ^1].join(" ")))

    cells.add(row)

  var table = cells.quickTable(title = title, noheaders = true,
                               borders = BorderNone, caption = caption)

  table.searchOne(@["table"]).get().defaultBg(false).bpad(0)
  for item in table.search(@["tr"]):
    item.bgColor("darkslategray")

  result = $table

  if len(nimbleDirs) > 0:
    cells = @[@[atom("Package"), atom("Location")]]

    for k, v in nimbleDirs:
      cells.add(@[atom(k), atom(v)])

    table = cells.quickTable(title = "Nimble packages used",
                             borders = BorderNone)
    table.searchOne(@["table"]).get().defaultBg(false)
    for item in table.search(@["tr"]):
      item.bgColor("darkslategray")

    result &= $table


proc split*(str: seq[Rune], ch: Rune): seq[seq[Rune]] =
  var start = 0

  for i in 0 ..< len(str):
    if str[i] == ch:
      result.add(str[start ..< i])
      start = i + 1

  result.add(str[start .. ^1])

proc setCon4mVerbosity*(level: C4Verbosity) =
  verbosity = level

proc getCon4mVerbosity*(): C4Verbosity =
  return verbosity

proc setCurrentFileName*(s: string) =
  curFileName = s

proc getCurrentFileName*(): string =
  return curFileName

proc formatCompilerError*(msg: string,
                          t:   Con4mToken,
                          tb:  string = "",
                          ii:  InstInfo): string =
  let
    me = getAppFileName().splitPath().tail

  result =  $color(me, "red") & ": " & $color(curFileName, "jazzberry") & ": "

  if t != nil:
    result &= fmt"{t.lineNo}:{t.lineOffset+1}: "
  result &= "\n" & $(text(msg))

  if t != nil and verbosity in [c4vShowLoc, c4vMax]:
    let
      line   = t.lineNo - 1
      offset = t.lineOffset + 1
      src    = t.cursor.runes
      lines  = src.split(Rune('\n'))
      pad    = repeat((' '), offset + 1)

    result &= "\n" & "  " & $(lines[line]) & "\n"
    result &= $(pad) & "^"

  if verbosity in [c4vTrace, c4vMax]:
    if tb != "":
      var throwinfo = ""
      if ii.line != 0:
        throwinfo &= "Exception thrown at: "
        throwinfo &= ii.filename & "(" & $(ii.line) & ":" & $(ii.column) & ")"
      result &= "\n" & formatTb(tb, throwinfo)

proc rawPublish(level: LogLevel, msg: string) {.inline.} =
  publishParams["loglevel"] = $(level)
  discard publish(con4mTopic, msg & "\n", publishParams)

proc fatal*(baseMsg: string,
            token:   Con4mToken,
            st:      string   = "",
            ii:      InstInfo = default(InstInfo)) =
  # 'Fatal' from con4m's perspective is throwing an exception that
  # returns to the caller.
  var msg: string

  if token == nil:
    msg = baseMsg
  elif token.lineNo == -1:
    msg = "(in code called by con4m): " & baseMsg
  else:
    msg = baseMsg

  raise newException(Con4mError, formatCompilerError(msg, token, st, ii))

template fatal*(msg: string, node: Con4mNode = nil) =
  var st   = ""

  when not defined(release):
    st = getStackTrace()

  if node == nil:
    fatal(msg, Con4mToken(nil), st)
  else:
    fatal(msg, node.token.getOrElse(nil), st, instantiationInfo())

proc setCTrace*() =
  setLogLevel(llTrace)
  setCon4mVerbosity(c4vMax)
  rawPublish(llTrace, "debugging on.")

proc ctrace*(msg: string) =
  if verbosity == c4vMax:
    rawPublish(llTrace, msg)
