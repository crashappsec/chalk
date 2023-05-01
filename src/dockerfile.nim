import tables, streams, strutils, options, unicode, json, nimutils

# RUN and COPY accept << and <<-
# This one is particularly a HFS:
# RUN <<FILE1 cat > file1 && <<FILE2 cat > file2
# I am
# first
# FILE1
# I am
# second
# FILE2

# FROM [--platform=<platform>] <image> [AS <name>]
# FROM [--platform=<platform>] <image>[:<tag>] [AS <name>]
# FROM [--platform=<platform>] <image>[@<digest>] [AS <name>]
# RUN [--mount=<options>] <command>
# RUN '[' "executable", "param1", "param2" ']'
# RUN [--network] <command>
# CMD '[' ... ']
# CMD <command>
# LABEL <key>=<value> [<key>=<value>]*    # Value can be in " quotes "
# LABEL description="This text illustrates \
# that label-values can span multiple lines."
# MAINTAINER string
# EXPOSE <port>[/(tcp|udp)] ...
# ENV key=<value> [...
# ADD [--chown=<user>:<group>] [--chmod=<perms>] [--checksum=<checksum>] <src>... <dest>
#ADD [--chown=<user>:<group>] [--chmod=<perms>] ["<src>",... "<dest>"]]
#ADD --checksum=sha256:24454f830cdb571e2c4ad15481119c43b3cafd48dd869a9b2945d1036d1dc68d https://mirrors.edge.kernel.org/pub/linux/kernel/Historic/linux-0.01.tar.gz /

# ADD --link <src>... <dest>
# COPY [--chown=<user>:<group>] [--chmod=<perms>] <src>... <dest>
# COPY [--chown=<user>:<group>] [--chmod=<perms>] ["<src>",... "<dest>"]
# COPY --link <src>... <dest>
# ENTRYPOINT ["executable", "param1", "param2"]
# ENTRYPOINT command param1 param2
# VOLUME '[' "/data", ... ']' | VOLUME "/data" "/data2"
# USER <user>[:<group>]
# USER <UID>[:<GID>]
# WORKDIR /path/to/workdir
# ARG <name>[=<default value>]
# ONBUILD <INSTRUCTION> [NOT FROM OR MAINTAINER]
# STOPSIGNAL signal
# HEALTHCHECK [OPTIONS] CMD command
# HEALTHCHECK NONE
# SHELL ["executable", "parameters"]
#
#

#const applyEnvVars = ["ADD", "COPY", "ENV", "EXPOSE", "FROM", "LABEL",
#                      "STOPSIGNAL", "USER", "VOLUME", "WORKDIR", "ONBUILD"]
#const knownCommands = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE",
#                       "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER",
#                       "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
#                       "HEALTHCHECK", "SHELL"]

const validDockerDirectives = ["syntax", "escape"]

type
  DockerDirective* = ref object
    name*:       string
    rawArg*:     string
    escapeChar*: Option[Rune]

  DockerCommand * = ref object
    name*:   string
    rawArg*: string
    continuationLines*: seq[int]  # line 's we continue onto.
    errors*: seq[string]

  VarSub* = ref object
    brace:    bool
    name*:    string
    startix*: int
    endix*:   int
    default*: Option[LineToken]
    error*:   string
    plus*:    bool
    minus*:   bool  #
  LineTokenType* = enum ltOther, ltWord, ltQuoted, ltSpace

  LineToken* = ref object
    # Line tokens with variable substitutions can be a nested tree,
    # because variable substitutions can, when providing default values,
    # have their own substitutions (which can have their own substitutions...)
    #
    # To construct the post-eval string, combine the contents array, with
    # each 'joiner' being a variable substitution operation.
    #
    # The individual pieces in the 'contents' field will be de-quoted
    # already, with escapes processed.
    startix*:    int
    endix*:      int
    kind*:       LineTokenType
    contents*:   seq[string]
    varSubs*:    seq[VarSub]
    quoteType*:  Option[Rune]
    usedEscape*: bool
    error*:      string

  Flag* = ref object
    name*:    string
    valid*:   bool
    argtoks*: seq[LineToken]

  TopLevelTokenType = enum tltComment, tltWhiteSpace, tltCommand, tltDirective
  TopLevelToken = ref object
    startLine*: int # 0-indexed
    errors*:    seq[string]
    case kind*: TopLevelTokenType
    of tltCommand:
      cmd*: DockerCommand
    of tltDirective:
      directive*: DockerDirective
    else: discard
  CmdParseType* = enum cpFrom, cpUnknown

  DockerParse* = ref object
    currentEscape:      Rune
    stream:             Stream
    expectContinuation: bool
    seenRun:            bool
    curLine:            int
    directives:         OrderedTable[string, DockerDirective]
    args*:              Table[string, string]  # Name to default value
    envs*:              Table[string, string]
    commands*:          seq[DockerCommand]
    sourceLines*:       seq[string] # The unparsed input text
    tokens*:            seq[TopLevelToken]
    errors*:            seq[string] # Not the only place errors live for now.
    inArgs*:            Table[string, string]

  InfoBase* = ref object of RootRef
    error*:    string

  FromInfo* = ref object of InfoBase
    flags*:  seq[Flag]
    image*:  Option[LineToken]
    tag*:    Option[LineToken]
    digest*: Option[LineToken]
    asArg*:  Option[LineToken]

  ShellInfo* = ref object of InfoBase
    json*:  string

  CmdInfo* = ref object of InfoBase
    contents*:     string
    json*:         bool
    toks*:         seq[LineToken]

  EntryPointInfo* = ref object of InfoBase
    contents*:     string
    json*:         bool
    toks*:         seq[LineToken]

  OnBuildInfo* = ref object of InfoBase
    rawContents*:  string

  AddInfo* = ref object of InfoBase
    flags*:  seq[Flag]
    rawSrc*: seq[string]
    rawDst*: string

  CopyInfo* = ref object of InfoBase
    flags*:  seq[Flag]
    rawSrc*: seq[string]
    rawDst*: string

  LabelInfo* = ref object of InfoBase
    labels*: OrderedTable[string, string]

proc evalOneVarSub(ctx:    DockerParse,
                   sub:    VarSub,
                   errors: var seq[string]): string
proc evalSubstitutions*(ctx:    DockerParse,
                        t:      LineToken,
                        errors: var seq[string]): string =
  for i, s in t.contents:
    result &= s
    if i + 1 != len(t.contents):
      result &= ctx.evalOneVarSub(t.varSubs[i], errors)

proc evalSubstitutions*(ctx:    DockerParse,
                        list:   seq[LineToken],
                        errors: var seq[string]): string =
  for item in list:
    result &= ctx.evalSubstitutions(item, errors)

proc evalOrReturnEmptyString*(ctx: DockerParse,
                              field: Option[LineToken],
                              errors: var seq[string]): string =
    if not field.isSome():
        return ""
    return ctx.evalSubstitutions(field.get(), errors)

when (NimMajor, NimMinor) < (1, 7):  {.warning[LockLevel]: off.}
method repr*(x: InfoBase, ctx: DockerParse): string {.base.} =
  raise newException(Exception, "Unimplemented.")

method repr*(x: FromInfo, ctx: DockerParse): string =
  var errors: seq[string] = @[]
  result = "FROM: "
  for flag in x.flags:
    let valid = if flag.valid: "valid" else: "NOT valid"
    result &= "(flag " & flag.name & " is " & valid & "; val = "
    result &= ctx.evalSubstitutions(flag.argToks, errors) & ") "
  if x.image.isNone():
    result &= "image = none??; "
  else:
    result &= "image = " & ctx.evalSubstitutions(x.image.get(), errors) & "; "
  if x.tag.isSome():
    result &= "digest = " & ctx.evalSubstitutions(x.tag.get(), errors) & "; "
  elif x.digest.isSome():
    result &= "digest = " & ctx.evalSubstitutions(x.digest.get(), errors) & "; "
  if x.asArg.isSome():
    result &= "ARG = " & ctx.evalSubstitutions(x.asArg.get(), errors)
  result &= "\n"

  if x.error != "":
    errors.add(x.error)

  if len(errors) != 0:
    result &= "ERRORS:\n"
    for item in errors:
      result &= item & "\n"

method repr*(x: ShellInfo, ctx: DockerParse): string =
  result = "SHELL: " & x.json
  if x.error != "":
    result &= " (json parse failed: " & x.error & ")"
  result &= "\n"

method repr*(x: CmdInfo, ctx: DockerParse): string =
  result = "CMD: "
  if x.json:
    result &= x.contents & "\n"
    if x.error != "":
      result &= "ERRORS:\n" & x.error & "\n"
    return
  else:
    var errors: seq[string] = @[]
    result &= ctx.evalSubstitutions(x.toks, errors)
    if x.error != "":
      errors.add(x.error)

    if len(errors) != 0:
      result &= "ERRORS:\n"
      for item in errors:
        result &= item & "\n"

method repr*(x: EntryPointInfo, ctx: DockerParse): string =
  result = "ENTRYPOINT: "
  if x.json:
    result &= x.contents & "\n"
    if x.error != "":
      result &= "ERRORS:\n" & x.error & "\n"
    return
  else:
    var errors: seq[string] = @[]
    result &= ctx.evalSubstitutions(x.toks, errors)
    if x.error != "":
      errors.add(x.error)

    if len(errors) != 0:
      result &= "ERRORS:\n"
      for item in errors:
        result &= item & "\n"

method repr*(x: OnBuildInfo, ctx: DockerParse): string =
  result = "ONBUILD: " & x.rawContents & "\n"

method repr*(x: AddInfo, ctx: DockerParse): string =
  result = "ADD " & $(x.rawSrc) & " to " & x.rawDst
  if x.error != "":
    result &= " (error: " & x.error & ")"
  result &= "\n"

method repr*(x: CopyInfo, ctx: DockerParse): string =
  result = "COPY " & $(x.rawSrc) & " to " & x.rawDst
  if x.error != "":
    result &= " (error: " & x.error & ")"
  result &= "\n"

proc lexOneLineTok(ctx: DockerParse, s: seq[Rune], i: var int): LineToken

proc lexVarSub(ctx: DockerParse, s: seq[Rune], i: var int): VarSub =
  result = VarSub(startix: i)

  i += 1
  if s[i] == Rune('{'):
    result.brace = true
    i += 1
  else:
    result.brace = false

  let nameStart = i

  while i < s.len() and s[i].isIdContinue():
    i += 1

  result.name = $(s[nameStart ..< i])

  if result.brace == false:
    result.endix = i
    return
  case s[i]
  of Rune('}'):
    i += 1
    result.endix = i
    return
  of Rune(':'):
    i += 1
    case s[i]
    of Rune('+'):
      result.plus = true
      # Drops down below
    of Rune('-'):
      result.minus = true
      # Drops down below
    else:
      result.error = "Unterminated ${"
      result.endIx = i
      return
  else:
    result.error = "Unterminated ${"
    result.endIx = i
    return

  i += 1
  result.default = some(ctx.lexOneLineTok(s, i))
  if s[i] != Rune('}'):
    result.error = "Unterminated ${"
  else:
    i += 1

proc lexQuoted(ctx: DockerParse, s: seq[Rune], q: Rune, i: var int):
              LineToken =
  result = LineToken(kind: ltQuoted, quoteType: some(q), startix: i)
  var val = ""
  while i < s.len():
    if s[i] == ctx.currentEscape:
      result.usedEscape = true
      i += 1
      case s[i]
      of Rune('n'):
        val &= "\n"
      of Rune('t'):
        val &= "\t"
      else:
        val &= $(s[i])
      i += 1
      continue
    if s[i] == q:
      i += 1
      result.contents.add(val)
      result.endix = i
      return
    if s[i] == Rune('$'):
      result.contents.add(val)
      val = ""
      result.varSubs.add(ctx.lexVarsub(s, i))
      continue
    val &= $(s[i])
    i += 1

  result.endix = i
  result.error = "Unterminated string"
  result.contents.add(val)

const nonWordRunes = [Rune('$'), Rune('"'), Rune('\''), Rune('#'), Rune('='),
                      Rune('{'), Rune('}')]

proc lexWord(ctx: DockerParse, s: seq[Rune], i: var int): LineToken =
  result = LineToken(kind: ltWord, startix: i)
  var val = ""

  while i < s.len():
    if s[i] == ctx.currentEscape:
      i += 1
      val &= $(s[i])
      i += 1
      continue
    if s[i] == Rune('$'):
      let varsub = ctx.lexVarSub(s, i)
      result.contents.add(val)
      val = ""
      result.varSubs.add(varsub)
      if not varsub.brace:
        result.endix = i
        return
      continue
    elif not s[i].isWhiteSpace() and s[i] notin nonWordRunes:
      val &= $(s[i])
      i = i + 1
      continue
    else:
      break

  result.contents.add(val)
  result.endix = i
  return

proc lexWhiteSpace(ctx: DockerParse, s: seq[Rune], i: var int): LineToken =
  result = LineToken(kind: ltSpace, startix: i)

  while i < s.len() and s[i].isWhiteSpace():  i += 1
  result.endix    = i
  result.contents = @[$(s[result.startix ..< result.endix])]

proc lexOneLineTok(ctx: DockerParse, s: seq[Rune], i: var int): LineToken =
  let c = s[i]
  case c
  of Rune('"'), Rune('\''):
    i += 1
    return ctx.lexQuoted(s, c, i)
  of Rune('$'):
    return ctx.lexWord(s, i)
  else:
    if c.isWhiteSpace():
      return ctx.lexWhiteSpace(s, i)
    if c == ctx.currentEscape or c notin nonWordRunes:
      return ctx.lexWord(s, i)
    i += 1
    result = LineToken(kind: ltOther, contents: @[$(c)])

proc lexSubableLine(ctx: DockerParse, s: string): seq[LineToken] =
  let all = s.toRunes()
  var i   = 0

  while i < len(all): result.add(ctx.lexOneLineTok(all, i))

proc parseOneFlag(ctx: DockerParse, toks: seq[LineToken], i: var int):
                 Option[Flag] =
  # This assumes there might be bool flags someday.
  var res = Flag()

  if len(toks) - i <= 2:                                   return none(Flag)
  if toks[i].kind != ltOther or toks[i+1].kind != ltOther: return none(Flag)

  let tok = toks[i+2]
  i += 3
  if tok.kind != ltWord or len(tok.varSubs) != 0 or tok.usedEscape:
    res.valid = false

  # Note: if it's an invalid flag name, this truncates what was there.
  res.name = tok.contents[0]

  # Docker doesn't accept spaces around either side of the =.
  if i == len(toks) or toks[i].kind != ltOther or toks[i].contents[0] != "=":
    return some(res)
  i = i + 1

  while i < len(toks) and toks[i].kind != ltSpace:
    res.argtoks.add(toks[i])
    i = i + 1

  return some(res)

proc basicParseAllFlags(ctx: DockerParse, toks: seq[LineToken], i: var int):
                       seq[Flag] =

  var oneOptFlag = ctx.parseOneFlag(toks, i)
  while oneOptFlag.isSome():
    result.add(oneOptFlag.get())
    if i == len(toks) or toks[i].kind != ltSpace: break
    i += 1

proc skipWhiteSpace(toks: seq[LineToken], i: var int) {.inline.} =
  if i < len(toks) and toks[i].kind == ltSpace: i += 1

proc nestedSubstitution(ctx:    DockerParse,
                        val:    string,
                        errors: var seq[string]): string =
  if "$" notin val: return val
  let
    starterrlen = len(errors)
    toks        = ctx.lexSubableLine(val)

  result = ctx.evalSubstitutions(toks, errors)

  if len(errors) != starterrlen:
    errors.add("Error when attempting environment substitution on value " &
      "provided from an env var.  Value was: " & val)

proc evalOneVarSub(ctx:    DockerParse,
                   sub:    VarSub,
                   errors: var seq[string]): string =
  let name = sub.name.toUpperAscii()
  if name in ctx.envs:
    if sub.plus:
      return ctx.evalSubstitutions(sub.default.get(), errors)
    else:
      return ctx.nestedSubstitution(ctx.envs[name], errors)

  elif name in ctx.args:
    if sub.plus:
      return ctx.evalSubstitutions(sub.default.get(), errors)
    else:
      return ctx.nestedSubstitution(ctx.args[name], errors)

  if sub.minus:
    return ctx.evalSubstitutions(sub.default.get(), errors)

  errors.add("Variable '" & name & "' was not set; using the empty string.")

  return ""

# Cannot have substitutions, so it's easy to parse.
proc parseArg*(ctx: DockerParse, t: DockerCommand) =
  let i = t.rawArg.find("=")
  if i == -1:
    ctx.args[t.rawArg] = ""
  else:
    let
      name = unicode.strip(t.rawArg[0 ..< i])
      val  = unicode.strip(t.rawArg[i + 1 .. ^1])

    ctx.args[name] = val

proc parseEnvNoEq(ctx: DockerParse, toks: seq[LineToken]): seq[string] =
  if toks[0].kind != ltWord or len(toks[0].varSubs) != 0:
    return @["Expected a single non-quoted word w/o $ subs on the LHS"]

  var errs: seq[string] = @[]

  ctx.envs[toks[0].contents[0]] = ctx.evalSubstitutions(toks[2 .. ^1], errs)

  return errs

proc parseEnvWithEq(ctx: DockerParse, toks: seq[LineToken]): seq[string] =
  var
    toApply: Table[string, string]
    errs:    seq[string] = @[]
    i:       int         = 0

  while i <= len(toks) - 3:
    if toks[i].kind != ltWord or len(toks[i].varSubs) != 0:
      if toks[i + 1].contents[0] != "=":
        errs.add("Invalid word value on the RHS, must be a single item")
        i += high(int32)
        continue
      errs.add("Expected a single non-quoted word w/o $ subs on the LHS")
      i += 3
      continue
    if toks[i+1].kind != ltOther or toks[i+1].contents[0] != "=":
      errs.add("Expected the 3rd token to be a = or a space")
      i += 3
      continue
    toApply[toks[i].contents[0]] = ctx.evalSubstitutions(toks[i+2], errs)
    i += 3
    continue

  if i < len(toks):
    errs.add("Stray crap at end of line")

  return errs

# Returns any errors.
proc parseEnv*(ctx: DockerParse, t: DockerCommand): seq[string] =
  let toks = ctx.lexSubableLine(t.rawArg)

  if len(toks) == 0:
    return @["No argument to ENV given."]
  if len(toks) < 3:
    return @["No value set."]

  case toks[1].kind
  of ltSpace:
    return ctx.parseEnvNoEq(toks)
  of ltOther:
    if toks[1].contents[0] != "=":
      return
    return ctx.parseEnvWithEq(toks)
  else:
    return @["Expected the 3rd token to be a = or a space"]

proc parseAddOrCopy*[T: InfoBase](ctx: DockerParse, t: DockerCommand): T =
  let toks = ctx.lexSubableLine(t.rawArg)
  var i    = 0
  var args: seq[string]
  var errs: seq[string]

  result       = T()
  result.flags = ctx.basicParseAllFlags(toks, i)

  skipWhiteSpace(toks, i)

  if len(toks) == i:
    result.error = "No arguments given"
    return

  while i != len(toks):
    if toks[i].kind == ltOther:
      result.error = "Unknown token in argument"
      return
    args.add(ctx.evalSubstitutions(toks[i], errs))
    i += 1
    skipWhiteSpace(toks, i)

  result.rawDst = args[^1]
  result.rawSrc = args[0 ..< ^1]

  if len(errs) != 0:
    result.error = errs.join("\n")

proc parseFrom*(ctx: DockerParse, t: DockerCommand): FromInfo =
  let toks = ctx.lexSubableLine(t.rawArg)
  var i    = 0

  result       = FromInfo()
  result.flags = ctx.basicParseAllFlags(toks, i)

  skipWhiteSpace(toks, i)

  if len(toks) == i or toks[i].kind == ltOther:
    result.error = "No image name provided."
    return

  result.image = some(toks[i])

  i += 1
  if len(toks) <= i: return

  if toks[i].kind == ltOther and i + 1 != len(toks):
    case toks[i].contents[0]
    of ":":
      i += 1
      if toks[i].kind == ltSpace:
        result.error = "Missing image tag after ':'"
        return
      result.tag = some(toks[i])
      i += 1
    of "@":
      i += 1
      if toks[i].kind == ltSpace:
        result.error = "Missing image digest after '@'"
        return
      result.digest = some(toks[i])
      i += 1
    else:
      result.error = "Unrecognized value after image: '" & toks[i].contents[0]
      return

  skipWhiteSpace(toks, i)
  if i == len(toks): return

  let t = toks[i]
  if t.kind != ltWord or len(t.varSubs) != 0 or
     t.contents[0].toUpperAscii() != "AS":
    result.error = "Expected end of command or 'AS' but got extra crap"
    return

  i += 1
  skipWhiteSpace(toks, i)

  if i == len(toks):
    result.error = "Got 'AS' without an argument"
    return

  if toks[i].kind == ltOther:
    result.error = "Got puncuation instead of a name for 'AS' argument"
    return

  result.asArg = some(toks[i])
  if i + 1 < len(toks):
    result.error = "Expected end of command but got extra crap"

proc parseLabel*(ctx: DockerParse, t: DockerCommand): LabelInfo =
  result   = LabelInfo()
  let toks = ctx.lexSubableLine(t.rawArg)
  var
    i      = 0
    errs: seq[string]

  skipWhiteSpace(toks, i)
  while i + 2 < len(toks):
    if toks[i].kind == ltOther:
      result.error = "Expected a label (got punctuation)"
      return
    let label = ctx.evalSubstitutions(toks[i], errs)
    i += 1
    if toks[i].kind != ltOther or toks[i].contents[0] != "=":
      result.error = "Expected '='"
      return
    i += 1
    case toks[i].kind
    of ltSpace:
      result.labels[label] = ""
    of ltOther:
      result.error = "Expected a label value"
      return
    else:
      result.labels[label] = ctx.evalSubstitutions(toks[i], errs)
      i += 1
    skipWhiteSpace(toks, i)

proc parseShell*(ctx: DockerParse, t: DockerCommand): ShellInfo =
  result = ShellInfo(json: t.rawArg)
  try:
    let
      json = parseJson(t.rawArg)
    if json.getElems().len() == 0:
      result.error = "JSON was not a list (or an empty list)"
  except:
    result.error = "JSON did not parse."

proc parseEntryPoint*(ctx: DockerParse, t: DockerCommand): EntryPointInfo =
  let s = unicode.strip(t.rawArg)
  result = EntryPointInfo(contents: s)

  if s.startsWith("["):
    result.json = true
    try:
      discard parseJson(s)
    except:
      result.error = "Argument started with '[' but wasn't valid JSON"
  else:
    result.toks = ctx.lexSubableLine(s)

proc parseCmd*(ctx: DockerParse, t: DockerCommand): CmdInfo =
  let s = unicode.strip(t.rawArg)
  result = CmdInfo(contents: s)

  if s.startsWith("["):
    result.json = true
    try:
      discard parseJson(s)
    except:
      result.error = "Argument started with '[' but wasn't valid JSON"
  else:
    result.toks = ctx.lexSubableLine(s)

proc parseOnBuild*(ctx: DockerParse, t: DockerCommand): OnBuildInfo =
  return OnBuildInfo(rawContents: t.rawArg)

proc `$`*(p: TopLevelToken): string =
  result = "[" & $(p.kind) & " @" & $(p.startLine)

  case p.kind
  of tltCommand:
    result &= ": " & p.cmd.name & " " & p.cmd.rawArg & "]"
  of tltDirective:
    result &= ": " & p.directive.name & " " & p.directive.rawArg & "]"
  else:
    result &= "]"

proc `$`*(p: DockerParse): string =
  for token in p.tokens: result &= $token & "\n"

proc newTok(ctx: DockerParse, kind: TopLevelTokenType): TopLevelToken =
  result = TopLevelToken(kind: kind, startLine: ctx.curLine, errors: @[])
  ctx.tokens.add(result)

proc parseHashLine(ctx: DockerParse, line: string) =
  let eqLoc = line.find("=")

  if eqLoc == -1:
    discard ctx.newTok(tltComment)
    return

  let
    # Since the only valid commands right now are ascii, we can
    # skip unicode handling here.
    name = unicode.strip(line[1 ..< eqLoc]).toLowerAscii()
    arg  = unicode.strip(line[eqLoc + 1 .. ^1])
    tok  = ctx.newTok(tltDirective)

  tok.directive = DockerDirective(name: name, rawArg: arg)
  if name == "escape":
    case arg.runeLen()
    of 1:
      tok.directive.escapeChar  = some(arg.runeAt(0))
      ctx.currentEscape         = arg.runeAt(0)
    of 0:
      tok.errors.add("escape directive without an escape character provided")
    else:
      tok.directive.escapeChar  = some(arg.runeAt(0))
      ctx.currentEscape         = arg.runeAt(0)
      tok.errors.add("Escape character is multi-byte... not allowed.")

  if name notin validDockerDirectives:
    tok.errors.add("Unknown docker directive: '" & name & " '")

  if name in ctx.directives:
    tok.errors.add("Docker directive '" & name & "' has already appeared")

  ctx.directives[name] = tok.directive

proc topLevelCmdParse(s: string): (string, string) =
  let asRunes = s.toRunes()
  var name: string
  var rest: string
  var started  = false
  var haveName = false

  for i, item in asRunes:
    if not started:
       if item.isWhiteSpace(): continue
       name = $(item)
       started = true
       continue
    elif not haveName:
      if item.isWhiteSpace():
        haveName = true
      else:
        name &= $(item)
      continue

    rest &= $(item)

  return (name.toUpperAscii(), rest)

proc parseCommandLine(ctx: DockerParse) =
  var cmd: DockerCommand
  let line = ctx.sourceLines[ctx.curLine]

  if ctx.expectContinuation:
    cmd = ctx.commands[^1]
    cmd.rawArg &= line
    cmd.continuationLines.add(ctx.curLine)
  else:
    let tok = ctx.newTok(tltCommand)
    # Not parsing the command until after we read the joined lines
    cmd = DockerCommand(rawArg: line)
    tok.cmd = cmd

  let (runeLast, rlen) = cmd.rawArg.lastRune(cmd.rawArg.len() - 1)

  if runeLast == ctx.currentEscape:
    cmd.rawArg = cmd.rawArg[0 ..< cmd.rawArg.len() - rlen]
    ctx.expectContinuation = true
    return

  (cmd.name, cmd.rawArg) = topLevelCmdParse(cmd.rawArg)

  ctx.commands.add(cmd)

proc topLevelLex(ctx: DockerParse) =
  for i, srcline in ctx.sourceLines:
    ctx.curLine = i
    let line = unicode.strip(srcline)
    if len(line) == 0:
      discard ctx.newTok(tltWhiteSpace)
    elif line[0] == '#':
      ctx.parseHashLine(line)
    else:
      ctx.parseCommandLine() # Don't send me the stripped version.

proc baseDockerParse*(s: Stream): DockerParse =
  result = DockerParse(stream: s, sourceLines: s.readAll().split("\n"),
                       currentEscape: Rune('\\'))
  result.topLevelLex()

template firstFromCheck() =
  if not gotFirstFrom:
    errors.add("Got bad commands before first FROM")
    gotFirstFrom = true # Don't keep erroring

proc parseAndEval*(s:      Stream,
                   args:   Table[string, string],
                   errors: var seq[string]): (DockerParse, seq[InfoBase]) =
  var
    parse        = s.baseDockerParse()
    gotFirstFrom = false
    res: seq[InfoBase] = @[]

  parse.inArgs = args

  for tok in parse.tokens:
    if len(tok.errors) != 0:
      errors &= tok.errors

    if tok.kind != tltCommand: continue
    let cmd = tok.cmd
    if len(cmd.errors) == 0:
      errors &= cmd.errors
    case cmd.name
    of "RUN":
      firstFromCheck()
      parse.args.clear()
    of "ARG":
      parse.parseArg(cmd)
    of "ENV":
      firstFromCheck()
      errors &= parse.parseEnv(cmd)
    of "FROM":
      gotFirstFrom = true
      res.add(parse.parseFrom(cmd))
    of "SHELL":
      firstFromCheck()
      res.add(parse.parseShell(cmd))
    of "LABEL":
      firstFromCheck()
      res.add(parse.parseLabel(cmd))
    of "ENTRYPOINT":
      firstFromCheck()
      res.add(parse.parseEntryPoint(cmd))
    of "CMD":
      firstFromCheck()
      res.add(parse.parseCmd(cmd))
    of "ONBUILD":
      firstFromCheck()
      res.add(parse.parseOnBuild(cmd))
    of "ADD":
      firstFromCheck()
      res.add(parseAddOrCopy[AddInfo](parse, cmd))
    of "COPY":
      firstFromCheck()
      res.add(parseAddOrCopy[CopyInfo](parse, cmd))
    else:
      firstFromCheck()

  return (parse, res)

when isMainModule:
  var
    f = newFileStream("test.docker")
    args: Table[string, string]
    errors: seq[string] = @[]

  let (parse, info) = f.parseAndEval(args, errors)
  for item in info:
    echo item.repr(parse)
    if item of EntryPointInfo:
        echo "it's an entrypoint"
    if item of CmdInfo:
        echo "ohhlol it's cmdinfo!"

  if len(errors) != 0:
    echo "ADDITIONAL ERRORS:"
    for item in errors:
      echo item
