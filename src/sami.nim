import tables, argparse, sugar
import nimutils, config, inject, extract, delete, builtins, defaults, help
import macros except error

const validDefaultCommands = ["help", "insert", "extract", "version"]
  
type
  SettrFunc    = (bool) -> void
  BoolFlagSpec = tuple[trueS, trueL, falseS, falseL, settr: string]

# Rather than manually repeating the logic for boolean flags over and over,
# we stick info about them in a list and then automatically processes.
const globalNoOptionFlags: seq[BoolFlagSpec] = @[
  (trueS:  "-c",
   trueL:  "--color",
   falseS: "-C",
   falseL: "--no-color",
   settr:  "setColor"),
  (trueS:  "-d",
   trueL:  "--dry-run",
   falseS: "-D",
   falseL: "--no-dry-run",
   settr:  "setDryRun"),
  (trueS:  "-p",
   trueL:  "--publish-defaults",
   falseS: "-P",
   falseL: "--no-publish-defaults",
   settr:  "setPublishDefaults")]
  
const artifactNoOptionFlags: seq[BoolFlagSpec] = @[
  (trueS:  "-r",
   trueL:  "--recursive",
   falseS: "-R",
   falseL: "--no-recursive",
   settr:  "setRecursive") ]
                     
# The base configuration will load when we import config.  We forego
# using any SAMI-specific builtns in that config, because it's just
# specification (otherwise we'd load those builtins there).
#
# But we want to go ahead and add these before we run any user
# definable config.
loadAdditionalBuiltins()

# The internally stored config file loads due to the import of the
# config module.  We want that configuration to run before we process
# command-line flags, because it might disable some behaviors that the
# flags should not be allowed to clobber.  So, we process that
# internal configuration validation before we process any command-line
# flags.
#
# This could also run automatically on importing config, but the
# plugins module also sets up some stuff that should load before the
# config is validated (some loaded plugins set up callbacks in con4m,
# for instance).  Even if we put "import plugins" before "import
# config", plugins imports config, so that will have its
# initialization code run first.  Thus, this gets done here, where we
# can be sure that it will happen after each module has set up what it
# needs.
doAdditionalValidation()

proc runCmdDefaults() {.inline.} =
  discard # The code that calls us will already print defaults.

proc runCmdInsert(ignored: seq[string]) {.inline.} =
  doInjection() # inject.nim

proc runCmdExtract(ignored: seq[string]) {.inline.} =
  let extractions = doExtraction() # extract.nim
  if extractions.isSome():
    publish("extract", extractions.get())
  else:
    warn("No items extracted.")

proc runCmdDelete(ignored: seq[string]) {.inline.} =
  doDelete() # delete.nim

proc runCmdConfDump(arglist: seq[string]) {.inline.} =
  var toDump = defaultConfig
  
  if len(arglist) > 1:
    error("'confdump' command takes one argument (or 0 to dump to stdout)")
    quit(1)
  if not getCanDump():
    error("Dumping the embedded configuration is disabled.")
    quit(1)
  let `selfSami?` = getSelfExtraction()

  if `selfSami?`.isSome():
    let selfSami = `selfSami?`.get()
    
    if selfSami.contains("X_SAMI_CONFIG"):
      toDump   = unpack[string](selfSami["X_SAMI_CONFIG"])
      
  publish("confdump", defaultConfig)
  
proc runCmdConfLoad(arg: string) {.inline.} =
  # The fact that we're injecting into ourself will be special-cased
  # in the injection workflow.
  let selfSami = getSelfExtraction()

  if not getCanLoad():
    error("Loading a new embedded configuration is disabled.")
    quit(1)
  else:
    setupSelfInjection(arg)
    doInjection()

proc runCmdVersion() =
  var
    rows = @[@["Sami version", getSamiExeVersion()],
             @["Build OS", hostOS],
             @["Build CPU", hostCPU],
             @["Build Date", CompileDate],
             @["Build Time", CompileTime]]
    t    = samiTableFormatter(2, rows=rows)

  t.setTableBorders(false)
  t.setNoHeaders()

  publish("version", t.render() & "\n")
                     
              
proc runCmdHelp(args: seq[string] = @["main"]) =
  doHelp(args)
  
proc flagToId(s: string): string =
  return s[2 .. ^1].replace("-", "")

proc oneBoolFlagCheck(opts, fn: NimNode, field1, field2: string): NimNode =
  let
    ident1 = newIdentNode(flagToId(field1))
    ident2 = newIdentNode(flagToId(field2))
    lit1   = newLit(field1)
    lit2   = newLit(field2)

  return quote do:
    if `opts`.`ident1` == `opts`.`ident2`:
      if `opts`.`ident1`:
        error("Two conflicting flags provided: '" & `lit1` & "' and '" &
          `lit2` & "'")
        quit()
    elif `opts`.`ident1`:
      `fn`(true)
    else:
      `fn`(false)
  
macro genBoolFlagChecks(opts: untyped,
                        specs: static[seq[BoolFlagSpec]]): untyped =
  result = newStmtList()
  
  for spec in specs:
    result.add(oneBoolFlagCheck(opts,
                                newIdentNode(spec.settr),
                                spec.trueL,
                                spec.falseL))
    
var configLoaded = false

# Since the argparse library doesn't give us a way to declare aliases,
# we generate the same block of code multiple times, once per alias,
# but make sure they all call the same function, whose name will be
# picked based on the first argument of `names`.
#
# The `alias` parameter is what we want to be able to type to have a
# particular command run.  The `cmd` parameter is the "proper" name of
# the command, which dictates which function we'll call when the
# command triggers.  For instance, if `cmd` is set to `extract`,
# then this code will call the proc `runCmdExtract` aabove.
#    
# If the `artifact` flag is true, then we will both set the artifact
# search path based on the args (if provided), and we will add in
# the --recursive / --no-recursive flags.
#
# If `hasArg` is true, the generated command will call setArgs to make
# argv available to the program generically.  Note that, if `artifact`
# is true, you should ALWAYS set this to true as well.
#
# If `nargs` is true, this field is passed on to the `nargs` field of
# the underlying argparse library.  It allows you to declare a fixed #
# of arguments, or -1 for variable.  So if a command can take 0 or 1
# arguments, you still have to pass in -1, then do the check in
# your `runCmdWhatever` proc.
macro declareCommand(names:    static[seq[string]],
                     artifact: bool,
                     hasArg:   bool,
                     nargs:    int) =
  result = newStmtList()

  let
    cmd      = newLit(names[0])
    funcName = newIdentNode("runCmd" & names[0])
  
  for name in names:
    let
      alias    = newLit(name)
      oneAlias = quote do:
        command(`alias`):
          when `artifact`:
            for tup in artifactNoOptionFlags:
              flag(tup.trueS, tup.trueL)
              flag(tup.falseS, tup.falseL)
            arg("theArgs", default = some("."), nargs = `nargs`)
          elif `hasArg`:
            arg("theArgs", nargs = `nargs`)
          run:
            setCommandName(`cmd`)

            when `artifact`:
              genBoolFlagChecks(opts, artifactNoOptionFlags)
              if len(opts.theArgs) > 0:
                setArtifactSearchPath(opts.theArgs)
            when `hasArg`:
              when type(opts.theArgs) is string:
                setArgs(@[opts.theArgs])
              else:
                setArgs(opts.theArgs)
    
            if not configLoaded and `cmd` notin ["load", "help"]:
              quit(1)
          
            when `hasArg` or `artifact`:
              `funcName`(opts.theArgs)
            else:
              `funcName`()
        
            showConfig()
            quit()
            
    result.add(oneAlias)

when isMainModule:
  configLoaded = loadUserConfigFile(getSelfExtraction())
  var cmdLine  = newParser:
    noHelpFlag()
    flag("-h", "--help")
    option("-f", "--config-file")
    option("-l", "--log-level",
           choices = @["none", "error", "warn", "info", "verbose", "trace"])
    for tup in globalNoOptionFlags:
      flag(tup.trueS, tup.trueL)
      flag(tup.falseS, tup.falseL)
    declareCommand(@["insert", "inject", "ins", "in", "i"], true, true, -1)
    declareCommand(@["extract", "ex", "x"], true, true, -1)
    declareCommand(@["delete", "del"], true, true, -1)
    declareCommand(@["defaults", "def"], false, false, 0)
    declareCommand(@["confdump", "dump"], false, true, -1)
    declareCommand(@["confload", "load"], false, true, 1)
    declareCommand(@["version", "vers", "v"], false, false, 0)
    declareCommand(@["help", "h"], false, true, -1)
    run:
      if opts.help:
        runCmdHelp()
        quit(1)
      genBoolFlagChecks(opts, globalNoOptionFlags)
      if opts.logLevel != "":
        setLogLevel(opts.logLevel)
      if opts.configFile != "":
        let
          confFile     = opts.configFile
          (head, tail) = confFile.splitPath()
        # In the builtin config file you can specify the path to
        # search for an external config file, and that path gets
        # searched.  So instead of special-casing, we take the -f as
        # setting the config path to the single item to search.
        setConfigPath(@[head])
        setConfigFileName(tail)
  try:
    var argv = commandLineParams()

    if len(argv) == 0:
      var
        `cmd?` = getDefaultCommand()
        cmd: string
          
      if `cmd?`.isSome():
        cmd = `cmd?`.get()
        if cmd notin validDefaultCommands:
          error("Default command '" & cmd & "' is not a valid default value.")
        else:
          argv.add(cmd)
    if len(argv) != 0:
      cmdLine.run(argv)
    
    error("No valid command given.")
    stderr.writeLine("Run '" & getAppFileName().splitPath().tail &
                     " help' for more information.")
    quit(1)
  except UsageError:
    stderr.writeLine(getCurrentExceptionMsg())
    stderr.writeLine("Run '" & getAppFileName().splitPath().tail &
                     " help' for more information.")
  except:
    stderr.writeLine("The program terminated abnormally.")
    stderr.writeLine(getCurrentExceptionMsg())
    publish("debug", getCurrentException().getStackTrace())
    
    quit(1)
