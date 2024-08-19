## This is a partial redo of nimutils argParse capability, but with
## more functionality and the specification of commands, flags and
## options checked via a c42 spec.
##
## If you call the API directly, and didn't do the input checking,
## results are undefined :)

import unicode, options, tables, os, sequtils, types, nimutils, st, eval,
       algorithm, typecheck, std/terminal
import strutils except strip

const errNoArg = "Expected a command but didn't find one"

type
  ArgFlagKind*    = enum
    afPair, afChoice, afStrArg, afMultiChoice, afMultiArg
  FlagSpec* = ref object
    reportingName*:    string
    clobberOk*:        bool
    recognizedNames*:  seq[string]
    doc*:              string
    callback*:         Option[CallbackObj]
    fieldToSet*:       string
    finalFlagIx*:      int
    noColon*:          bool   # Inherited from the command object.
    noSpace*:          bool   # Also inherited from the command object.
    argIsOptional*:    bool   # When true, --foo bar is essentially --foo="" bar
    case kind*:        ArgFlagKind
    of afPair:
      helpFlag*:       bool
      boolValue*:      OrderedTable[int, bool]
      positiveNames*:  seq[string]
      negativeNames*:  seq[string]
      linkedChoice*:   Option[FlagSpec]
    of afChoice, afMultiChoice:
      choices*:        seq[string]
      selected*:       OrderedTable[int, seq[string]]
      linkedYN*:       Option[FlagSpec]
      min*, max*:      int
    of afStrArg:
      strVal*:         OrderedTable[int, string]
    of afMultiArg:
      strArrVal*:      OrderedTable[int, seq[string]]
  CommandSpec* = ref object
    commands*:          OrderedTable[string, CommandSpec]
    reportingName*:     string
    allNames*:          seq[string]
    flags*:             OrderedTable[string, FlagSpec]
    callback*:          Option[CallbackObj]
    doc*:               string
    noColon*:           bool # accept --flag= f but not --flag:f.
    noSpace*:           bool # Docker-style if true *:
    extraHelpTopics*:   OrderedTable[string, string]
    argName*:           string
    minArgs*:           int
    maxArgs*:           int
    subOptional*:       bool
    unknownFlagsOk*:    bool
    dockerSingleArg*:   bool
    noFlags*:           bool
    autoHelp*:          bool
    finishedComputing*: bool
    parent*:            Option[CommandSpec]
    allPossibleFlags*:  OrderedTable[string, FlagSpec]

  ArgResult* = ref object
    stashedTop*:  AttrScope
    command*:     string
    args*:        OrderedTableRef[string, seq[string]]
    flags*:       OrderedTable[string, FlagSpec]
    helpToPrint*: string
    parseCtx*:    ParseCtx
  ParseCtx = ref object
    curArgs:    seq[string]
    args:       seq[string]
    res:        ArgResult
    i:          int
    foundCmd*:  bool
    parseId*:   int # globally unique parse ID.
    finalCmd*:  CommandSpec

proc getValue*(f: FlagSpec): Box =
  case f.kind
  of afPair:        return pack(f.boolValue[f.finalFlagIx])
  of afChoice:      return pack(f.selected[f.finalFlagIx][0])
  of afMultiChoice: return pack(f.selected[f.finalFlagIx])
  of afStrArg:      return pack(f.strVal[f.finalFlagIx])
  of afMultiArg:    return pack(f.strArrVal[f.finalFlagIx])

proc flagSpecEq(f1, f2: FlagSpec): bool =
  if f1 == f2:           return true   # They're literally the same ref
  if f1.kind != f2.kind: return false
  if f1.reportingName == f2.reportingName: return true
  return false

proc newSpecObj*(reportingName: string       = "",
                 allNames: openarray[string] = [],
                 minArgs                     = 0,
                 maxArgs                     = 0,
                 subOptional                 = false,
                 unknownFlagsOk              = false,
                 dockerSingleArg             = true,
                 noFlags                     = false,
                 doc                         = "",
                 argName                     = "",
                 callback                    = none(CallbackObj),
                 parent                      = none(CommandSpec),
                 noColon                     = false,
                 noSpace                     = false): CommandSpec =
  if noFlags and unknownFlagsOk:
    raise newException(ValueError, "Can't have noFlags and unknownFlagsOk")
  return CommandSpec(reportingName:     reportingName,
                     allNames:          allNames.toSeq(),
                     minArgs:           minArgs,
                     maxArgs:           maxArgs,
                     subOptional:       subOptional,
                     unknownFlagsOk:    unknownFlagsOk,
                     dockerSingleArg:   dockerSingleArg,
                     noFlags:           noFlags,
                     doc:               doc,
                     argName:           argName,
                     callback:          callback,
                     parent:            parent,
                     noColon:           noColon,
                     noSpace:           noSpace,
                     autoHelp:          false,
                     finishedComputing: false)

proc addCommand*(spec:            CommandSpec,
                 name:            string,
                 aliases:         openarray[string]   = [],
                 subOptional:     bool                = false,
                 unknownFlagsOk:  bool                = false,
                 noFlags:         bool                = false,
                 dockerSingleArg: bool                = false,
                 doc:             string              = "",
                 argName:         string              = "",
                 callback:        Option[CallbackObj] = none(CallbackObj),
                 noColon:         bool                = false,
                 noSpace:         bool                = false):
                   CommandSpec {.discardable.} =
  ## Creates a command under the top-level argument parsing spec,
  ## or a sub-command under some other command.
  ## The `name` field is the 'official' name of the command, which
  ## will be used in referencing the command programatically, and
  ## when producing error messages.
  ##
  ## The values in `aliases` can be used at the command line in
  ##
  ## place of the official name.
  ##
  ## If there are sub-commands, then the `subOptional` flag indicates
  ## whether it's okay for the sub-command to not be provided.
  ##
  ## If `unknownFlagsOk` is provided, then you can still add flags
  ## for that section, but if the user does provide flags that wouldn't
  ## be valid in any section, then they will still be accepted.  In
  ## this mode, unknown flags are put into the command arguments.
  ##
  ## If `noFlags` is provided, then the rest of the input will be
  ## treated as arguments, even if they start with dashes.  If this
  ## flag is set, unknownFlagsOk cannot be set, and there may not
  ## be further sub-commands.
  ##
  ## Note that, if you have sub-commands that are semantically the
  ## same, you still should NOT re-use objects. The algorithm for
  ## validating flags assumes that each command object to be unique,
  ## and you could definitely end up accepting invalid flags.
  result = newSpecObj(reportingName   = name,
                      allNames        = aliases,
                      subOptional     = subOptional,
                      unknownFlagsOk  = unknownFlagsOk,
                      dockerSingleArg = dockerSingleArg,
                      noFlags         = noFlags,
                      noColon         = noColon,
                      noSpace         = noSpace,
                      doc             = doc,
                      argName         = argName,
                      callback        = callback,
                      parent          = some(spec))

  if name notin result.allNames: result.allNames.add(name)
  for oneName in result.allNames:
    if oneName in spec.commands:
      raise newException(ValueError, "Duplicate command: " & name)
    spec.commands[oneName] = result

proc addArgs*(cmd:      CommandSpec,
              min:      int = 0,
              max:      int = high(int)): CommandSpec {.discardable.} =
  ## Adds an argument specification to a CommandSpec.  Without adding
  ## it, arguments won't be allowed, only flags.
  ##
  ## This returns the command spec object passed in, so that you can
  ## chain multiple calls to addArgs / flag add calls.

  result = cmd
  if min < 0 or max < 0 or min > max:
    raise newException(ValueError, "Invalid arguments")

  cmd.minArgs     = min
  cmd.maxArgs     = max

proc newFlag(cmd:             CommandSpec,
             kind:            ArgFlagKind,
             reportingName:   string,
             clOk:            bool,
             recognizedNames: openarray[string],
             doc:             string = "",
             callback:        Option[CallbackObj] = none(CallbackObj),
             toSet:           string = "",
             optArg:          bool = false,
            ): FlagSpec =
  if cmd.noFlags:
    raise newException(ValueError,
                       "Cannot add a flag for a spec where noFlags is true")

  result = FlagSpec(reportingName: reportingName, kind: kind, clobberOk: clOk,
                    recognizedNames: recognizedNames.toSeq(), doc: doc,
                    callback: callback, fieldToSet: toSet, noColon: cmd.noColon,
                    noSpace: cmd.noSpace, argIsOptional: optArg)
  cmd.flags[reportingName] = result

proc addChoiceFlag*(cmd:             CommandSpec,
                    reportingName:   string,
                    recognizedNames: openarray[string],
                    choices:         openarray[string],
                    flagPerChoice:   bool                = false,
                    multi:           bool                = false,
                    clobberOk:       bool                = false,
                    doc:             string              = "",
                    callback:        Option[CallbackObj] = none(CallbackObj),
                    toSet:           string              = ""):
                      FlagSpec {.discardable.} =
  ## This creates a flag for `cmd` that requires a string argument if
  ## provided, but the string argument must be from a fixed set of
  ## choices, as specified in the `choices` field.
  ##
  ## If `flagPerChoice` is provided, then we add a yes/no flag for
  ## each choice, which, on the command-line, acts as a 'boolean'.
  ## But, the value will be reflected in this field, instead.
  ##
  ## For instance, if you add a '--log-level' choice flag with values
  ## of ['info', 'warn', 'error'], then these two things would be
  ## equal:
  ##
  ## --log-level= warn
  ##
  ## --warn
  ##
  ## And you would still check the value after parsing via the name
  ## 'log-level'.
  ##
  ## The `name`, `aliases` and `clobberOk` fields work as with other
  ## flag types.

  let kind            = if multi: afMultiChoice else: afChoice
  var flag            = newFlag(cmd, kind, reportingName, clobberOk,
                                recognizedNames, doc, callback, toSet)
  flag.choices        = choices.toSeq()
  if flagPerChoice:
    for item in choices:
      let itemName = "->" & item # -> for forwards...
      var oneFlag = newFlag(cmd, afPair, itemName, clobberOk, @[item],
                            doc, callback)
      oneFlag.positiveNames = @[item]
      oneFlag.linkedChoice  = some(flag)

  result = flag

proc addYesNoFlag*(cmd:           CommandSpec,
                   reportingName: string,
                   yesValues:     openarray[string],
                   noValues:      openarray[string] = [],
                   clobberOk:     bool = false,
                   doc:           string = "",
                   callback:      Option[CallbackObj] = none(CallbackObj),
                   toSet:         string              = ""):
                     FlagSpec {.discardable.} =

  var both   = yesValues.toSeq()
  both       = both & noValues.toSeq()
  var ynFlag = newFlag(cmd, afPair, reportingName, clobberOk, both,
                       doc, callback, toSet)

  ynFlag.positiveNames = yesValues.toSeq()
  ynFlag.negativeNames = noValues.toSeq()

  if reportingName notin yesValues and reportingName notin noValues:
    let c      = cmd.addChoiceFlag("->" & reportingName,
                                          recognizedNames = @[reportingName],
                                          choices = both, clobberOk = clobberOk)
    c.linkedYN = some(ynFlag)

  result = ynFlag

proc addFlagWithArg*(cmd:             CommandSpec,
                     reportingName:   string,
                     recognizedNames: openarray[string]   = [],
                     multi:           bool                = false,
                     clobberOk:       bool                = false,
                     doc:             string              = "",
                     callback:        Option[CallbackObj] = none(CallbackObj),
                     toSet:           string              = "",
                     optArg:          bool                = false):
                       FlagSpec {.discardable.} =
  ## This simply adds a flag that takes a required string argument, or,
  ## in the case of multi-args, an array of string arguments.  The arguments
  ## are identical in semantics as for other flag types.

  let kind  = if multi: afMultiArg else: afStrArg
  result = newFlag(cmd, kind, reportingName, clobberOk, recognizedNames,
                   doc, callback, toSet, optArg)

template argpError(msg: string) =
  var fullError = msg

  if ctx.res.command != "":
    fullError = "When parsing command '" & ctx.res.command & "': " & msg

  raise newException(ValueError, fullError)

template argpError(flagName: string, msg: string) =
  argpError("--" & flagName & ": " & msg)

proc validateOneFlag(ctx:     var ParseCtx,
                     name:    string,
                     inspec:  FlagSpec,
                     foundArg = none(string)) =
  var
    argCrap = foundArg
    spec    = inspec
    flagSep = if not spec.noColon: [':', '='] else: ['=', char(0)]

  if ctx.i < len(ctx.args) and ctx.args[ctx.i][0] in flagSep:
    if argCrap.isNone() and not spec.noSpace:
      argCrap = some(ctx.args[ctx.i][1 .. ^1].strip())
      ctx.i = ctx.i + 1
      if argCrap.get() == "":
        if ctx.i < len(ctx.args):
          argCrap = some(ctx.args[ctx.i])
          ctx.i = ctx.i + 1
        else:
          argpError(name, "requires an argument.")

  if spec.kind == afPair:
    if argCrap.isSome():
      argpError(name, "takes no argument.")
    if spec.linkedChoice.isSome():
      spec    = spec.linkedChoice.get()
      argCrap = some(name)

  elif argCrap.isNone():
    if not spec.argIsOptional:
      # Here we require an argument, and we didn't find a ':' or '=',
      # so we just assume it's the next word, unless we see a dash
      # followed by anything (otherwise, we'll assume the dash itself
      # is the argument, since this often would mean 'stdin')
      if ctx.i == len(ctx.args) or (ctx.args[ctx.i][0] == '-' and
                                    len(ctx.args[ctx.i]) > 1):
        argpError(name, "requires an argument.")
      if spec.noSpace:
        argpError(name, "requires an argument.")
      argCrap = some(ctx.args[ctx.i].strip())
      ctx.i  = ctx.i + 1
    else:
      # When arguments are optional and we don't see them (or at least a
      # = or :), we set them to ""
      argCrap = some("")

  if spec.kind notin [afMultiChoice, afMultiArg] and
     not spec.clobberOk and spec.reportingName in ctx.res.flags:
    argpError(name, "redundant flag not allowed")

  case spec.kind
  of afPair:
    if   name in spec.positiveNames: spec.boolValue[ctx.parseId] = true
    elif name in spec.negativeNames: spec.boolValue[ctx.parseId] = false
    else: raise newException(ValueError, "Reached unreachable code")
  of afChoice:
    let arg = argCrap.get()
    if arg notin spec.choices:
      argpError(name, "Invalid choice: '" & arg & "'")
    if spec.linkedYN.isSome():
      spec = spec.linkedYN.get()
      if not spec.clobberOk and spec.reportingName in ctx.res.flags:
        argpError(name, "redundant flag not allowed")
      if arg in spec.positiveNames:   spec.boolValue[ctx.parseId] = true
      elif arg in spec.negativeNames: spec.boolValue[ctx.parseId] = false
      else: raise newException(ValueError, "Reached unreachable code")
    else:
      spec.selected[ctx.parseId] = @[arg]
  of afMultiChoice:
      let arg = argCrap.get()
      if arg notin spec.choices:
        argpError(name, "Invalid choice: '" & arg & "'")
      if ctx.parseId notin spec.selected:
        spec.selected[ctx.parseId] = @[arg]
      elif arg notin spec.selected[ctx.parseId]:
        spec.selected[ctx.parseId].add(arg)
  of afStrArg:
    spec.strVal[ctx.parseId] = argCrap.get()
  of afMultiArg:
    var parts = argCrap.get()
    if len(parts) != 0 and parts[^1] == ',':
      while ctx.i != len(ctx.args) and ctx.args[ctx.i][0] != '-':
        parts = parts & ctx.args[ctx.i].strip()
        ctx.i = ctx.i + 1
    if len(parts) != 0 and parts[^1] == ',': parts = parts[0 ..< ^1]
    if ctx.parseId notin spec.strArrVal:
      spec.strArrVal[ctx.parseId] = parts.split(",")
    else:
      spec.strArrVal[ctx.parseId] &= parts.split(",")

  ctx.res.flags[spec.reportingName] = spec

proc parseOneFlag(ctx: var ParseCtx, spec: CommandSpec, validFlags: auto) =
  var
    orig        = ctx.args[ctx.i]
    cur         = orig[1 .. ^1]
    singleDash  = true
    definiteArg = none(string)

  ctx.i = ctx.i + 1

  # I really want to change this to a while, just because I've
  # accidentally done three dashes once or twice.  But I'm going to
  # assume I'm in the minority and there's some common use case
  # where --- should be treated as an argument not a flag?
  if cur[0] == '-':
    cur        = cur[1 .. ^1]
    singleDash = false

  var
    colonix = if spec.noColon: -1 else: cur.find(':')
    eqix    = cur.find('=')
    theIx   = colonix

  if theIx == -1:
    theIx = eqIx
  else:
    if eqIx != -1 and eqIx < theIx:
      theIx = eqIx
  if theIx != -1:
    let rest    = cur[theIx+1 .. ^1].strip()
    cur         = cur[0 ..< theIx].strip()

    if len(rest) != 0:
      definiteArg = some(rest)
    elif ctx.i != len(ctx.args):
      definiteArg = some(ctx.args[ctx.i])
      ctx.i = ctx.i + 1

  if cur in validFlags:
    ctx.validateOneFlag(cur, validFlags[cur], definiteArg)
  elif not singleDash:
    if spec.unknownFlagsOk:
      ctx.curArgs.add(orig)
    else:
      argpError(cur, "Invalid flag")
  else:
    if spec.dockerSingleArg and len(cur) > 1 and $(cur[0]) in validFlags:
      let flag = $cur[0]
      ctx.validateOneFlag(flag, validFlags[flag], some(cur[1 .. ^1]))
    else:
      # Single-dash flags bunched together cannot have arguments, unless
      # unknownFlagsOk is on.
      if definiteArg.isSome() and not spec.unknownFlagsOk:
        argpError(cur, "Invalid flag")
      if spec.unknownFlagsOk:
        ctx.curArgs.add(orig)
      else:
        for i, c in cur:
          let oneCharFlag = $(c)
          if oneCharFlag in validFlags:
            ctx.validateOneFlag(oneCharFlag, validFlags[oneCharFlag])
          elif spec.unknownFlagsOk: continue
          elif i == 0: argpError(cur, "Invalid flag")
          else:
            argpError(cur, "Couldn't process all characters as flags")


proc buildValidFlags(inSpec: OrderedTable[string, FlagSpec]):
                    OrderedTable[string, FlagSpec] =
  for reportingName, f in inSpec:
    for name in f.recognizedNames:
      result[name] = f

proc parseCmd(ctx: var ParseCtx, spec: CommandSpec) =
  # If we are here, we know we're parsing for the spec passed in; it matched.
  # We accept that arguments and flags might be intertwined. We basically
  # will scan till we hit the end or hit a valid command that isn't
  # part of a flag argument.
  #
  # Then, we validate the number of arguments against the spec, handle
  # recursing if there's a sub-command, and decide if we're allowed to
  # finish if we have no more arguments to parse.
  var lookingForFlags = if spec.noFlags: false
                        else:            true

  ctx.curArgs = @[]

  let validFlags = spec.allPossibleFlags.buildValidFlags()

  # Check that any flags we happened to accept in a parent context
  # (because we were not sure what the exact sub-command would be),
  # are still valid now that we have more info about our subcommand.
  for k, _ in ctx.res.flags:
    if k notin spec.allPossibleFlags:
      argpError(k, "Not a valid flag for this command.")

  while ctx.i != len(ctx.args):
    let cur = ctx.args[ctx.i]
    # If len is 1, we pass it through, usually means 'use stdout'
    if lookingForFlags and len(cur) > 1 and cur[0] == '-':
      if cur == "--":
        lookingForFlags = false
        ctx.i           = ctx.i + 1
        continue
      try:
        ctx.parseOneFlag(spec, validFlags)
      except:
        # If we get an error when parsing a flag, but we don't have a
        # top-level command yet, we're going to scan the whole string
        # looking for any word that matches. If we find one, we'll
        # assume the intent was to use that command, but that the
        # error was with a flag.
        if ctx.foundCmd == false:
          while ctx.i != len(ctx.args):
            let cur = ctx.args[ctx.i]
            if cur in spec.commands:
              ctx.foundCmd = true
              break
            else:
              ctx.i = ctx.i + 1
        raise # Reraise.
      continue

    if cur in spec.commands:
      ctx.foundCmd = true
      ctx.i = ctx.i + 1
      if len(ctx.curArgs) < spec.minArgs:
        argpError("Too few arguments for command " & cur &
                  "(expected " & $(spec.minArgs) & ")")
      if len(ctx.curArgs) > spec.maxArgs:
        argpError("Too many arguments provided for command " & cur &
          " (max = " & $(spec.maxArgs) & ")")
      ctx.res.args[ctx.res.command] = ctx.curArgs
      let nextSpec = spec.commands[cur]
      if ctx.res.command != "":
        ctx.res.command &= "." & nextSpec.reportingName
      else:
        ctx.res.command             = nextSpec.reportingName
      ctx.res.args[ctx.res.command] = ctx.curArgs
      ctx.parseCmd(nextSpec)
      return

    ctx.curArgs.add(ctx.args[ctx.i])
    ctx.i = ctx.i + 1

  # If we exited the loop, we need to make sure the parse ended up in
  # a valid final state.
  if len(spec.commands) != 0 and not spec.subOptional:
    argpError(errNoArg)
  if len(ctx.curArgs) < spec.minArgs:
    argpError("Too few arguments (expected " & $(spec.minArgs) & ")")
  if len(ctx.curArgs) > spec.maxArgs:
    argpError("Too many arguments provided (max = " & $(spec.maxArgs) & ")")
  ctx.res.args[ctx.res.command] = ctx.curArgs
  ctx.finalCmd = spec

proc computePossibleFlags(spec: CommandSpec) =
  # Because we want to allow for flags for commands being passed to us
  # before we know whether they're valid (e.g., in a subcommand), we are
  # going to keep multiple flag states, one for each possible combo of
  # subcommands. To do this, we will flatten the tree of possible
  # subcommands, and then for each tree, we will compute all flags we
  # might see.
  #
  # The top of the tree will have all possible flags, but as we descend
  # we need to keep re-checking to see if we accepted flags that we
  # actually shouldn't have accepted.
  #
  # Note that we do not allow flag conflicts where the flag specs are
  # not FULLY compatible.  And, we do not allow subcommands to
  # re-define a flag that is defined already by a higher-level command.
  #
  # Note that, as we parse, we will accept flags we MIGHT smack down
  # later, depending on the command. We will validate what we've accepted
  # so far every time we enter a new subcommand.
  if spec.finishedComputing:
    return
  if spec.parent.isSome():
    let parentFlags = spec.parent.get().allPossibleFlags
    for k, v in parentFlags: spec.allPossibleFlags[k] = v
  for k, v in spec.flags:
    if k in spec.allPossibleFlags:
      raise newException(ValueError, "When checking flag '" & k &
        "', In section '" & spec.reportingName &
        "' -- command flag names cannot " &
        "conflict with parent flag names or top-level flag names." &
        "This is because we want to make sure users don't have to worry " &
        "about getting flag position right whenever possible."
      )
    spec.allPossibleFlags[k] = v

  var flagsToAdd: OrderedTable[string, FlagSpec]
  for _, kid in spec.commands:
    kid.computePossibleFlags()
    for k, v in kid.allPossibleFlags:
      if k in spec.allPossibleFlags: continue
      if k notin flagsToAdd:
        flagsToAdd[k] = v
        continue
      if not flagSpecEq(flagsToAdd[k], v):
        raise newException(ValueError, "Sub-commands with flags of the " &
          "same name must have identical specifications (flag name: " & k & ")")
  for k, v in flagsToAdd:
    spec.allPossibleFlags[k] = v
  spec.finishedComputing = true

var parseId = 0
proc parseOne(ctx: var ParseCtx, spec: CommandSpec) =
  ctx.i       = 0
  ctx.res     = ArgResult(parseCtx: ctx, args: OrderedTableRef[string, seq[string]]())
  ctx.parseId = parseId
  parseId     = parseId + 1
  ctx.parseCmd(spec)

proc ambiguousParse*(spec:          CommandSpec,
                     inargs:        openarray[string] = [],
                     defaultCmd:    Option[string]    = some("")):
                       seq[ArgResult] =
  ## This parse function accepts multiple parses, if a parse is
  ## ambiguous.
  ##
  ## First, it attempts to parse `inargs` as-is, based on the
  ## specification passed in `spec`.  If that fails because there was
  ## no command provided, what happens is based on the value of the
  ## `defaultCmd` field-- if it's none(string), then no further action
  ## is taken.  If there's a default command provided, it's re-parsed
  ## with that default command.
  ##
  ## However, you provide "" as the default command (i.e., some("")),
  ## then this will try all possible commands and return any that
  ## successfully parse.
  ##
  ## If `inargs` is not provided, it is taken from the system-provided
  ## arguments.  In nim, this is commandLineParams(), but would be
  ## argv[1 .. ] elsewhere.

  if defaultCmd.isSome() and spec.subOptional:
    raise newException(ValueError,
             "Can't have a default command when commands aren't required")
  var
    validParses   = seq[ParseCtx](@[])
    firstError    = ""
    args          = if len(inargs) != 0: inargs.toSeq()
                    else:                commandLineParams()

  # First, try to see if no inferencing results in a full parse
  spec.computePossibleFlags()

  var ctx = ParseCtx(args: args)

  try:
    ctx.parseOne(spec)
    return @[ctx.res]
  except:
    firstError = getCurrentExceptionMsg()
    if ctx.foundCmd or defaultCmd.isNone():
      raise
    # else, ignore.

  let default = defaultCmd.get()
  if default != "":
    try:    return spec.ambiguousParse(@[default] & args, none(string))
    except: firstError = getCurrentExceptionMsg()

  for cmd, ss in spec.commands:
    if ss.reportingName != cmd: continue
    var ctx = ParseCtx(args: @[cmd] & args)
    try:
      ctx.parseOne(spec)
      validParses.add(ctx)
    except:
      discard

  result = @[]
  for item in validParses: result.add(item.res)

  if len(result) == 0: raise newException(ValueError, firstError)

proc parse*(spec:       CommandSpec,
            inargs:     openarray[string] = [],
            defaultCmd: Option[string]    = none(string)): ArgResult =
  ## This parses the command line specified via `inargs` as-is using
  ## the `spec` for validation, and if that parse fails because no
  ## command was provided, then tries a single default command, if it
  ## is provided.
  ##
  ## If `inargs` is not provided, it is taken from the system-provided
  ## arguments.  In nim, this is commandLineParams(), but would be
  ## argv[1 .. ] elsewhere.
  ##
  ## The return value of type ArgResult can have its fields queried
  ## directly, or you can use getBoolValue(), getValue(), getCommand()
  ## and getArgs() to access the results.

  let allParses = spec.ambiguousParse(inargs, defaultCmd)
  if len(allParses) != 1:
    raise newException(ValueError, "Ambiguous arguments: please provide an " &
                                   "explicit command name")
  result = allParses[0]

type LoadInfo = ref object
  defaultCmd:     Option[string]
  defaultYesPref: seq[string]
  defaultNoPref:  seq[string]
  showDocOnErr:   bool
  errCmd:         string
  addHelpCmds:    bool

proc getSec(aOrE: AttrOrErr): Option[AttrScope] =
  if aOrE.isA(AttrErr) : return none(AttrScope)
  let aOrS = aOrE.get(AttrOrSub)
  if aOrS.isA(Attribute): return none(AttrScope)
  return some(aOrS.get(AttrScope))

template u2d(s: string): string = s.replace("_", "-")

proc loadYn(cmdObj: CommandSpec, all: AttrScope, info: LoadInfo) =
  for k, v in all.contents:
    let
      realName   = u2d(k)
      one        = v.get(AttrScope)
      yesAliases = unpack[seq[string]](one.attrLookup("yes_aliases").get())
      noAliases  = unpack[seq[string]](one.attrLookup("no_aliases").get())
      yesPrefOpt = one.attrLookup("yes_prefixes")
      noPrefOpt  = one.attrLookup("no_prefixes")
      doc        = unpack[string](one.attrLookup("doc").get())
      cbOpt      = one.attrLookup("callback")
      yesPref    = if yesPrefOpt.isSome(): unpack[seq[string]](yesPrefOpt.get())
                   else: info.defaultYesPref
      noPref     = if noPrefOpt.isSome(): unpack[seq[string]](noPrefOpt.get())
                   else: info.defaultNoPref
      cb         = if   cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                   else:                none(CallbackObj)
      ftsOpt     = one.attrLookup("field_to_set")
      fieldToSet = if ftsOpt.isSome(): unpack[string](ftsOpt.get())
                   else:               ""
    var
      yesNames = yesAliases
      noNames  = noAliases

    if len(yesPref) == 0:
      yesNames.add(realName)
    else:
      for prefix in yesPref:
        if prefix.endswith("-"): yesNames.add(prefix & realName)
        else:                    yesNames.add(prefix & "-" & realName)
    for prefix in noPref:
      if prefix.endswith("-"): noNames.add(prefix & realName)
      else:                    noNames.add(prefix & "-" & realName)

    cmdObj.addYesNoFlag(realName, yesNames, noNames, false, doc, cb, fieldToSet)

proc loadHelps(cmdObj: CommandSpec, one: AttrScope, info: LoadInfo) =
  let
    names = unpack[seq[string]](one.attrLookup("names").get())
    doc   = unpack[string](one.attrLookup("doc").get())

  cmdObj.addYesNoFlag("help", names, [], false, doc)

proc loadChoices(cmdObj: CommandSpec, all: AttrScope, info: LoadInfo) =
  for k, v in all.contents:
    let
      realName   = u2d(k)
      one        = v.get(AttrScope)
      aliases    = unpack[seq[string]](one.attrLookup("aliases").get())
      choices    = unpack[seq[string]](one.attrLookup("choices").get())
      addFlags   = unpack[bool](one.attrLookup("add_choice_flags").get())
      doc        = unpack[string](one.attrLookup("doc").get())
      cbOpt      = one.attrLookup("callback")
      cb         = if cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                   else:              none(CallbackObj)
      ftsOpt     = one.attrLookup("field_to_set")
      fieldToSet = if ftsOpt.isSome(): unpack[string](ftsOpt.get())
                   else:               ""

    var allNames = aliases & @[realName]

    cmdObj.addChoiceFlag(realName, allNames, choices, addFlags, false,
                         false, doc, cb, fieldToSet)

proc loadMChoices(cmdObj: CommandSpec, all: AttrScope, info: LoadInfo) =
  for k, v in all.contents:
    let
      realName   = u2d(k)
      one        = v.get(AttrScope)
      aliases    = unpack[seq[string]](one.attrLookup("aliases").get())
      choices    = unpack[seq[string]](one.attrLookup("choices").get())
      addFlags   = unpack[bool](one.attrLookup("add_choice_flags").get())
      doc        = unpack[string](one.attrLookup("doc").get())
      cbOpt      = one.attrLookup("callback")
      cb         = if cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                   else:              none(CallbackObj)
      min        = unpack[int](one.attrLookup("min").get())
      max        = unpack[int](one.attrLookup("min").get())
      ftsOpt     = one.attrLookup("field_to_set")
      fieldToSet = if ftsOpt.isSome(): unpack[string](ftsOpt.get())
                   else:               ""
    var
      allNames = aliases & @[realName]
      f        = cmdObj.addChoiceFlag(realName, allNames, choices, addFlags,
                                      true, false, doc, cb, fieldToSet)
    f.min = min
    f.max = max

proc loadFlagArgs(cmdObj: CommandSpec, all: AttrScope, info: LoadInfo) =
  for k, v in all.contents:
    let
      realName   = u2d(k)
      one        = v.get(AttrScope)
      aliases    = unpack[seq[string]](one.attrLookup("aliases").get())
      doc        = unpack[string](one.attrLookup("doc").get())
      cbOpt      = one.attrLookup("callback")
      cb         = if cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                   else:              none(CallbackObj)
      ftsOpt     = one.attrLookup("field_to_set")
      fieldToSet = if ftsOpt.isSome(): unpack[string](ftsOpt.get())
                   else:               ""
      optArg     = unpack[bool](one.attrLookup("optional_arg").get())

    var allNames = aliases & @[realName]

    cmdObj.addFlagWithArg(realName, allNames, false, false, doc,
                          cb, fieldToSet, optArg)

proc loadFlagMArgs(cmdObj: CommandSpec, all: AttrScope, info: LoadInfo) =
  for k, v in all.contents:
    let
      realName   = u2d(k)
      one        = v.get(AttrScope)
      aliases    = unpack[seq[string]](one.attrLookup("aliases").get())
      doc        = unpack[string](one.attrLookup("doc").get())
      cbOpt      = one.attrLookup("callback")
      cb         = if cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                   else:              none(CallbackObj)
      ftsOpt     = one.attrLookup("field_to_set")
      fieldToSet = if ftsOpt.isSome(): unpack[string](ftsOpt.get())
                   else:               ""
      optArg     = unpack[bool](one.attrLookup("optional_arg").get())

    var allNames = aliases & @[realName]

    cmdObj.addFlagWithArg(realName, allNames, true, false, doc,
                          cb, fieldToSet, optArg)

proc loadExtraTopics(cmdObj: CommandSpec, all: AttrScope) =
  for k, v in all.contents:
    cmdObj.extraHelpTopics[k] = unpack[string](v.get(Attribute).value.get())

proc loadSection(cmdObj: CommandSpec, sec: AttrScope, info: LoadInfo) =
  # The command object was created by the caller.  We need to:
  # 1) Add any flags spec'd.
  # 2) Create any subcommands spec'd.
  let
    commandOpt   = sec.attrLookup(["command"], 0, vlExists).getSec()
    flagYns      = sec.attrLookup(["flag_yn"], 0, vlExists).getSec()
    flagHelps    = sec.attrLookup(["flag_help"], 0, vlExists).getSec()
    flagChoices  = sec.attrLookup(["flag_choice"], 0, vlExists).getSec()
    flagMChoices = sec.attrLookup(["flag_multi_choice"], 0, vlExists).getSec()
    flagArgs     = sec.attrLookup(["flag_arg"], 0, vlExists).getSec()
    flagMArgs    = sec.attrLookup(["flag_multi_arg"], 0, vlExists).getSec()
    extraHelpSec = sec.attrLookup(["topics"], 0, vlExists).getSec()

  if flagYns.isSome():
    cmdObj.loadYn(flagYns.get(), info)
  if flagHelps.isSome():
    cmdObj.loadHelps(flagHelps.get(), info)
  if flagChoices.isSome():
    cmdObj.loadChoices(flagChoices.get(), info)
  if flagMChoices.isSome():
    cmdObj.loadMChoices(flagMChoices.get(), info)
  if flagArgs.isSome():
    cmdObj.loadFlagArgs(flagArgs.get(), info)
  if flagMArgs.isSome():
    cmdObj.loadFlagMArgs(flagMArgs.get(), info)
  if extraHelpSec.isSome():
    cmdObj.loadExtraTopics(extraHelpSec.get())
  if info.addHelpCmds and (commandOpt.isNone() or
                           "help" notin commandOpt.get().contents):
    if commandOpt.isNone():
      cmdObj.subOptional = true
    let help = cmdObj.addCommand("help", unknownFlagsOk = true)
    help.addArgs()
    help.autoHelp = true

  if commandOpt.isNone(): return

  let commands = commandOpt.get()

  for k, v in commands.contents:
    let
      one      = v.get(AttrScope)
      aliases  = unpack[seq[string]](one.attrLookup("aliases").get())
      argBox   = unpack[seq[Box]](one.attrLookup("args").get())
      minArg   = unpack[int](argBox[0])
      maxArg   = unpack[int](argBox[1])
      doc      = unpack[string](one.attrLookup("doc").get())
      argName  = unpack[string](one.attrLookup("arg_name").get())
      cbOpt    = one.attrLookup("callback")
      cb       = if cbOpt.isSome(): some(unpack[CallbackObj](cbOpt.get()))
                 else:              none(CallbackObj)
      asubmut  = unpack[bool](one.attrLookup("arg_sub_mutex").get())
      ignoreF  = unpack[bool](one.attrLookup("ignore_all_flags").get())
      igBOpt   = one.attrLookup("ignore_bad_flags")
      ignoreB  = if igBOpt.isSome():
                   unpack[bool](igBOpt.get())
                 else:
                   cmdObj.unknownFlagsOk
      dashFArg = unpack[bool](one.attrLookup("dash_arg_space_optional").get())
      colOkOpt = one.attrLookup("colon_ok")
      noCol    = if colOkOpt.isSome():
                   not unpack[bool](colOkOpt.get())
                 else:
                   cmdObj.noColon
      spOkOpt  = one.attrLookup("space_ok")
      noSpc    = if spOkOpt.isSome():
                   not unpack[bool](spOkOpt.get())
                 else:
                   cmdObj.noSpace
      sub      = cmdObj.addCommand(k, aliases, not asubmut, ignoreB, ignoreF,
                                   dashFArg, doc, argName, cb, noCol, noSpc)
    sub.addArgs(minArg, maxArg).loadSection(one, info)

proc stringizeFlags(inflags: OrderedTable[string, FlagSpec], id: int):
                     OrderedTableRef[string, string] =
  result = OrderedTableRef[string, string]()
  for f, spec in inflags:
    case spec.kind
    of afPair:        result[f] = $(spec.boolValue[id])
    of afChoice:      result[f] = $(spec.selected[id][0])
    of afMultiChoice: result[f] = spec.selected[id].join(",")
    of afStrArg:      result[f] = spec.strVal[id]
    of afMultiArg:    result[f] = spec.strArrVal[id].join(",")

proc stringizeFlags*(winner: ArgResult): OrderedTableRef[string, string] =

  return winner.flags.stringizeFlags(winner.parseCtx.parseId)

proc addDash(s: string): string =
  if len(s) == 1: return "-" & s
  else:            return "--" & s

proc getUsage(cmd: CommandSpec): Rope =
  var cmdName, flags, argName, subs: string

  if cmd.reportingName == "":
    cmdName = getAppFilename().splitPath().tail
  else:
    cmdname = cmd.reportingName.replace(".", " ")

  if cmd.maxArgs == 0:
    argName = ""
  else:
    for i in 0 ..< cmd.minArgs:
      argName &= cmd.argName & " "
    if cmd.minArgs != cmd.maxArgs:
      argName &= "[" & cmd.argName & "] "
      if cmd.maxArgs == high(int):
        argName &= "..."
      else:
        argName &= "(0, " & $(cmd.maxArgs - cmd.minArgs) & ") "

  if len(cmd.flags) != 0: flags = "[FLAGS]"

  if len(cmd.commands) != 0:
    if cmd.subOptional: subs = "[COMMANDS]"
    else:               subs = "COMMAND"

  return h1(strong("Usage:") + atom(" " & cmdname & " " & flags & " " &
    argName & subs))

proc getCommandList(cmd: CommandSpec): Rope =
  var
    title = "Available commands"
    cmds: seq[string]

  for k, sub in cmd.commands:
    if sub.reportingName notin cmds and sub.reportingName != "":
      cmds.add(sub.reportingName)

  result = paragraph(center(cmds.instantTable(width = 40, title = title)))

proc getAdditionalTopics(cmd: CommandSpec): Rope =
  var topics: seq[string]

  if cmd.extraHelpTopics.len() == 0: return
  for k, _ in cmd.extraHelpTopics:
    topics.add(k)

  topics.sort()
  if topics.len() != 0:
    result = topics.instantTable("Available topics")

proc getFlagHelp(cmd: CommandSpec): Rope =
  var
    flagList: seq[string]
    rows:     seq[seq[string]] = @[@["Flag", "Description"]]
    row:      seq[string]      = @[]
    aliases:  seq[string]
    numFlags: int
    fstr:     string

  for k, spec in cmd.flags:
    if not k.startswith("->"):
      flagList.add(k)

  if len(flaglist) == 0: return

  for k in flagList:
    let spec = cmd.flags[k]
    numFlags = len(spec.recognizedNames)
    if spec.reportingName in spec.recognizedNames:
      fstr = spec.reportingName.addDash()
      aliases = @[]
      for item in spec.recognizedNames:
        if item != spec.reportingName:
          aliases.add(item.addDash())

    else:
      fstr = spec.recognizedNames[0].addDash()
      aliases = @[]
      for item in spec.recognizedNames[1 .. ^1]:
        aliases.add(item.addDash())

    case spec.kind
    of afPair:
      if spec.reportingName notin spec.positiveNames:
        # TODO... implement this branch.  Don't need for chalk tho.
        discard
      else:
        fstr    = spec.reportingName.addDash()
        aliases = @[]
        for item in spec.positiveNames:
          if item != spec.reportingName:
            aliases.add(item.addDash())
        if len(aliases) != 0:
          fstr &= "\nor: " & aliases.join(", ")
        rows.add(@[fstr, spec.doc])
        if len(spec.negativeNames) != 0:
          aliases = @[]
          fstr = spec.negativeNames[^1].addDash()
          for item in spec.negativeNames[0 ..< ^1]:
            aliases.add(item.addDash())
          if len(aliases) != 0:
            fstr &= "\nor: " & aliases.join(", ")
          rows.add(@[fstr, "Does the opposite of the row above."])
    of afChoice:
      fstr &= "= " & spec.choices.join(" | ")
      if len(aliases) != 0:
        fstr &= "\nor: " & aliases.join(", ")
      rows.add(@[fstr, spec.doc])
    of afMultiChoice:
      fstr &= "= " & spec.choices.join(",")
      if spec.min == spec.max:
        fstr &= "(select " & $(spec.min) & ") "
      if len(aliases) != 0:
        fstr &= "\nor: " & aliases.join(", ")
      rows.add(@[fstr, spec.doc])
    of afStrArg:
      fstr &= "= ARG"
      if len(aliases) != 0:
        fstr &= "\nor: " & aliases.join(", ")
      rows.add(@[fstr, spec.doc])
    of afMultiArg:
      fstr &= "= ARG,ARG,..."
      if len(aliases) != 0:
        fstr &= "\nor: " & aliases.join(", ")
      rows.add(@[fstr, spec.doc])

  if len(rows) != 0:
    result = quickTable(rows, "Command Flags")

proc getOneCmdHelp(cmd: CommandSpec): Rope =
  result = getUsage(cmd) + pre(markdown(cmd.doc))

  if len(cmd.commands) != 0:
     result += cmd.getCommandList()

  var f = cmd.getFlagHelp()
  result += f

  if len(cmd.extraHelpTopics) != 0:
    result += cmd.getAdditionalTopics()

type Corpus = OrderedFileTable

proc getHelp(corpus: Corpus, inargs: seq[string]): string =
  var
    args  = inargs
    r: Rope

  if len(args) == 0:
    args = @["main"]

  for arg in args:
    if arg notin corpus:
      if arg != "topics":
        r += h2(textRope("No such topic: ") + em(arg))
        continue

      var topics: seq[string] = @[]
      var widest              = 0

      for key, _ in corpus: topics.add(key)

      r += h1("Available Help Topics")

      r += (topics.instantTable())

    else:
      var processed = arg.replace('_', ' ')
      processed = $(Rune(processed[0]).toUpper()) & processed[1 .. ^1]

      r += markdown(unicode.strip(corpus[arg]))

  result = $(r)

  print(result)

proc getCmdHelp*(cmd: CommandSpec, args: seq[string]): string =

  var rope: Rope

  if len(args) == 0:
    rope = getOneCmdHelp(cmd)
  else:
    var legitCmds: seq[(bool, string, string)] = @[]

    for item in args:
      if item in cmd.commands and cmd.commands[item].reportingName == item:
        legitCmds.add((true, item, item))
      else:
        var found = false
        for sub, spec in cmd.commands:
          if item in spec.allNames:
            legitCmds.add((true, item, spec.reportingName))
            found = true
            break
        if not found:
          let eht = cmd.extraHelpTopics
          if item in eht:
            legitCmds.add((false, item, getHelp(Corpus(eht), @[item])))
          elif not item.startswith("-"):
            stderr.writeLine("No such command: " & item)

    if len(legitCmds) == 0:
      rope += getOneCmdHelp(cmd)
    else:
      for (c, given, reporting) in legitCmds:
        if not c:
          print(h1("Help for " & given), file = stderr)
          stderr.writeLine(reporting.indentWrap(hangingIndent = 0))
          continue
        if given != reporting:
          print(h1("Note: '" & given & "' is an alias for '" &
            reporting & "'"), stderr)

        rope += getOneCmdHelp(cmd.commands[reporting])

  print rope

proc managedCommit(winner: ArgResult, runtime: ConfigState): string =
  result = ""

  let
    parseId = winner.parseCtx.parseId
    endCmd  = winner.parseCtx.finalCmd

  for flag, spec in winner.flags:
    spec.finalFlagIx = parseId

    let
      val = case spec.kind
            of afPair:        pack(spec.boolValue[parseId])
            of afChoice:      pack(spec.selected[parseId][0])
            of afMultiChoice: pack(spec.selected[parseId])
            of afStrArg:      pack(spec.strVal[parseId])
            of afMultiArg:    pack(spec.strArrVal[parseId])
    if spec.callback.isSome():
        let
          retBox = runtime.sCall(spec.callback.get(), @[val]).get()
          ret    = unpack[string](retbox)
        if ret != "":
          raise newException(ValueError, ret)

    if spec.fieldToSet != "":
      let
        fieldType = case spec.kind
                    of afPair:             boolType
                    of afChoice, afStrArg: stringType
                    else:                  newListType(stringType)
      if not runtime.setOverride(spec.fieldToSet, some(val), fieldType):
        raise newException(ValueError, "Couldn't apply override to field " &
                           spec.fieldToSet)
  var
    cmdObj  = endCmd
    cmdName = winner.command
  while true:
    if cmdObj.callback.isSome():
      let args = @[pack(winner.args[cmdName])]
      discard runtime.sCall(cmdObj.callback.get(), args)
    if cmdObj.autoHelp:
      result = getCmdHelp(cmdObj.parent.get(), winner.args[cmdName])
    let parts = cmdName.split(".")
    cmdName = parts[0 ..< ^1].join(".")
    if cmdObj.parent.isNone(): break
    cmdObj = cmdObj.parent.get()

  let
    specTop     = winner.stashedTop
    cmdAttrBox  = specTop.attrLookup("command_attribute")
    flagAttrBox = specTop.attrLookup("flag_attribute")
    argAttrBox  = specTop.attrLookup("arg_attribute")

  if cmdAttrBox.isSome():
    discard runtime.attrSet(unpack[string](cmdAttrBox.get()),
                            pack(winner.command))
  if argAttrBox.isSome():
    discard runtime.attrSet(unpack[string](argAttrBox.get()),
                            pack(winner.args[winner.command]))
  if flagAttrBox.isSome():
    let flags = winner.flags.stringizeFlags(parseId)
    discard runtime.attrSet(unpack[string](flagAttrBox.get()), pack(flags))

proc finalizeManagedGetopt*(runtime: ConfigState,
                            options: seq[ArgResult],
                            outputHelp = true):
                          ArgResult =
  var matchingCmds: seq[string] = @[]
  let
    spectop    = options[0].stashedTop
    cmdAttrBox = spectop.attrLookup("command_attribute")

  if cmdAttrBox.isSome():
    let
      cmdLoc = unpack[string](cmdAttrBox.get())
      cmdBox = runtime.attrLookup(cmdLoc)

    if cmdBox.isSome():
      let cmd = unpack[string](cmdBox.get())

      for item in options:
        let thisCmd = item.command.split(".")[0]
        if cmd == thisCmd:
          item.helpToPrint = item.managedCommit(runtime)
          if outputHelp and item.helpToPrint != "":
            stderr.writeLine(item.helpToPrint)
          return item
        elif cmd == "":
          matchingCmds.add(thisCmd)

      if cmd == "":
        raise newException(ValueError, "Couldn't guess the command because " &
          "multiple commands match: " & matchingCmds.join(", "))
      # If we get here, there are one of two situations:
      # 1) The default command isn't an actual valid command, in
      #    which case whoever is using this API made a mistake
      # 2) We assumed a valid command, but when we added it to the front
      #    when we were trying all completions, we got a error.
      #    But, currently, we're throwing away bad error messages.
      #    So let's just give a pretty lame but clear message.

      raise newException(ValueError, "Bad command line: no explicit command " &
        "provided, and if we add the default command ('" & cmd & "') then " &
        "the result doesn't properly parse (add the explicit command " &
        " to see the error)")
  else:
    raise newException(ValueError,
                     "No command found in input, and no default command " &
                       "was provided by configuration.")

proc runManagedGetopt*(runtime:      ConfigState,
                       args:         seq[string],
                       getoptsPath = "getopts",
                       outputHelp  = true): seq[ArgResult] =
  # By this point, the spec should be validated, making the
  # checks for getopts() correctness unneeded.
  let aOrE = runtime.attrs.attrLookup(getoptsPath.split("."), 0, vlExists)
  if aOrE.isA(AttrErr):
    raise newException(ValueError, "Specified getopts section not found: " &
                       getOptsPath)
  let aOrS = aOrE.get(AttrOrSub)
  if aOrS.isA(Attribute):
    raise newException(ValueError, "The getopts path is a field not a section")
  let
    sec     = aOrS.get(AttrScope)
    argsOpt = sec.attrLookup("args")
    cmdSec  = sec.attrLookup(["command"], 0, vlExists)

  var
    minArg = 0
    maxArg = 0
    commandScope: AttrScope = nil
    li     = LoadInfo()

  if cmdSec.isA(AttrOrSub):
    let aOrS = cmdSec.get(AttrOrSub)
    commandScope = aOrS.get(AttrScope)
    if len(commandScope.contents) == 0:
      maxArg = high(int) # No commands provided, so default is to allow any args

  if argsOpt.isSome():
    let boxSeq = unpack[seq[Box]](argsOpt.get())
    minArg = unpack[int](boxSeq[0])
    maxArg = unpack[int](boxSeq[1])

  let
    defaultOpt = sec.attrLookup("default_command")
    yesBox     = sec.attrLookup("default_yes_prefixes").get()
    noBox      = sec.attrLookup("default_no_prefixes").get()
    docOnErr   = unpack[bool](sec.attrLookup("show_doc_on_err").get())
    errorCmd   = unpack[string](sec.attrLookup("error_command").get())
    colonOk    = unpack[bool](sec.attrLookup("colon_ok").get())
    spaceOk    = unpack[bool](sec.attrLookup("space_ok").get())
    ignoreBad  = unpack[bool](sec.attrLookup("ignore_bad_flags").get())
    addHelp    = unpack[bool](sec.attrLookup("add_help_commands").get())
    doc        = unpack[string](sec.attrLookup("doc").get())
    argName    = unpack[string](sec.attrLookup("arg_name").get())
    dashFArg   = unpack[bool](sec.attrLookup("dash_arg_space_optional").get())


  if defaultOpt.isNone(): li.defaultCmd = some("")
  else:                   li.defaultCmd = some(unpack[string](defaultOpt.get()))

  li.defaultYesPref = unpack[seq[string]](yesBox)
  li.defaultNoPref  = unpack[seq[string]](noBox)
  li.showDocOnErr   = docOnErr
  li.errCmd         = errorCmd
  li.addHelpCmds    = addHelp

  let topLevelCmd = newSpecObj(minArgs = minArg, maxArgs = maxArg, doc = doc,
                              argName = argName, unknownFlagsOk = ignoreBad,
                              dockerSingleArg = dashFArg, noColon = not colonOk,
                              noSpace = not spaceOk)
  topLevelCmd.loadSection(sec, li)

  result = topLevelCmd.ambiguousParse(args, defaultCmd = li.defaultCmd)

  for item in result:
    # We need to look up some items in this scope in managedCommit;
    # it's the top-level getopts() scope in the specification context.
    item.stashedTop = sec

  if len(result) == 1:
    let helpToPrint = result[0].managedCommit(runtime)
    if outputHelp:
      if helpToPrint != "":
        stderr.writeLine(helpToPrint)
    else:
      result[0].helpToPrint = helpToPrint
