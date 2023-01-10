import tables, strformat, argparse
import nimutils, config, inject, extract, delete, dump, plugins, builtins
import macros except error

# The base configuration will load when we import config.  We forego
# using any SAMI-specific builtns in that config, because it's just
# specification (otherwise we'd load those builtins there.
#
# But we want to go ahead and add these before we run any user definable
# config.
loadAdditionalBuiltins()

# The internally stored config file loads due to the import of config.
# Call this function to do the additional configuration validation
# before we process any command-line flags.  
#
# This could also run automatically on importing config, but the
# plugins module also sets up some stuff that should load before the
# config is validated (some loaded plugins set up callbacks in con4m,
# for instance).  Even if we put "import plugins" before "import
# config", plugins imports config, so that will have its
# initialization code run first.  Thus, this gets done here, where we
# can be sure that it will happen after each module has set up what it
# needs.
#
# Plus, it gives me the opportunity to point out some setup is
# happening before the command-line flag processing.
doAdditionalValidation()

proc runCmdDefaults() {.noreturn, inline.} =
  loadUserConfigFile(getSelfExtraction())
  # We can't really put this in loadUserConfigFile() unless we move
  # it, due to current module interdependencies.  Will probably fix
  # this sooner than later.
  showConfig() # config.nim
  quit()

proc runCmdInject() {.noreturn, inline.} =
  # This needs to be set before we load any user-level configuration
  # file, for the sake of the "injecting()" builtin (above).  Note: we
  # cannot use that builtin in the base configuration, since we run
  # that before we set up any command-line arguments; it would return
  # 'false' for us always, no matter what the user supplies.
  loadUserConfigFile(getSelfExtraction())
  loadCommandPlugins()
  doInjection() # inject.nim
  quit()

proc runCmdExtract() {.noreturn, inline.} =
  loadUserConfigFile(getSelfExtraction())
  let extractions = doExtraction() # extract.nim
  if extractions.isSome():
    publish("extract", extractions.get())
  else:
    warn("No items extracted.")
  quit()

proc runCmdDump(arglist: seq[string]) {.noreturn, inline.} =
  handleConfigDump(getSelfExtraction(), arglist)
  quit()
  
proc runCmdLoad() {.noreturn, inline.} =
  # The fact that we're injecting into ourself will be special-cased
  # in the injection workflow.
  let selfSami = getSelfExtraction()
    
  quitIfCantChangeEmbeddedConfig(selfSami)
  if len(getArgs()) != 1:
    error("configLoad requires either a file name or 'default'")
    quit()

  setupSelfInjection(getArgs()[0])
  loadCommandPlugins()
  doInjection()
  quit()

proc runCmdDel() {.noreturn, inline.} =
  loadUserConfigFile(getSelfExtraction())
  doDelete() # delete.nim
  quit()


const
  fColorShort         = "-a"
  fColorLong          = "--color"
  fNoColorShort       = "-A"
  fNoColorLong        = "--no-color"
  fDryRunShort        = "-d"
  fDryRunLong         = "--dry-run"
  fNoDryRunShort      = "-D"
  fNoDryRunLong       = "--no-dry-run"
  fSilentShort        = "-z"
  fSilentLong         = "--silent"
  fQuietShort         = "-q"
  fQuietLong          = "--quiet"
  fNormalShort        = "-n"
  fNormalLong         = "--normal-output"
  fVerboseShort       = "-i"
  fVerboseLong        = "--info"
  fTraceShort         = "-v"
  fTraceLong          = "--verbose"
  fCfgFileNameShort   = "-c"
  fCfgFileNameLong    = "--config-file-name"
  fCfgSearchPathShort = "-p"
  fCfgSearchPathLong  = "--config-search-path"
  fOverwriteShort     = "-w"
  fOverwriteLong      = "--overwrite"
  fNoOverwriteShort   = "-W"
  fNoOverwriteLong    = "--no-overwrite"
  fRecursiveShort     = "-r"
  fRecursiveLong      = "--recursive"
  fNoRecursiveShort   = "-R"
  fNoRecursiveLong    = "--no-recursive"

  # help strings for the command line.
  insertHelp      = "Insert SAMIs into artifacts"
  extractHelp     = "Extract SAMIs from artifacts"
  colorHelp       = "Turn on color in error messages"
  noColorHelp     = "Turn OFF color in error messages"
  dryRunHelp      = "Do not write files; output to terminal what would have\n" &
                    "\t\t\t     been done. Shows which files would have " &
                    "metadata\n\t\t\t     inserted / extracted, and " &
                    "what metadata is present"
  noDryRunHelp    = "Turn off dry run (if defined via env variable or conf file"
  silentHelp      = "Doesn't output any messages (except with --dry-run)"
  quietHelp       = "Only outputs if there's an error (or --dry-run output)"
  normalHelp      = "Output at normal logging level (warnings, but not " &
                    "too chatty)"
  verboseHelp     = "Output basic information during run"
  traceHelp       = "Output detailed tracing information"
  showDefHelp     = "Show what options will be selected. Considers\n" &
                    "\t\t\t     the impact of any config file, environment \n" &
                    "\t\t\t     variables and options passed before this " &
                    "flag appears"
  showDumpHelp    = "Dumps any embedded configuration to disk."
  showLoadHelp    = "Loads an embedded configuration from the specified file."
  showDelHelp     = "Remove SAMI objects from artifacts."
  delFilesHelp    = "Specify the files/directories from which to remove " &
                    "SAMIs from"
  cfgFileHelp     = "Specify the config file name to search for (NOT the path)"
  cfgSearchHelp   = "The search path for looking for configuration files"
  inFilesHelp     = "Specify which files or directories to target for " &
                    "insertion."
  dumpFileHelp    = "Specify the (optional) file to dump the embedded " &
                    "configuration file."
  loadFileHelp    = "Specify the configuration file to embed."
  overWriteHelp   = "Replace existing SAMI metadata found in an artifact"
  noOverWriteHelp = "Keep existing SAMI metadata found in an artifact by\n" &
                    "\t\t\t     embedding it in the OLD_SAMI field"
  recursiveHelp   = "Recurse any directories when looking for artifacts"
  noRecursiveHelp = "Do NOT recurse into dirs when looking for artifacts." &
                     "\t\t\t     If dirs are listed in arguments, the " &
                     "top-level files \t\t\t     will be checked, but " &
                     "no deeper."
  outFilesHelp    = "Specify files/directories from which to extract SAMIs from"
  eConflictFmt    = "Conflicting flags provided: {l1} ({s1}) and {l2} ({s2})"
  generalHelp     = """{prog}: insert or extract software artifact metadata.
Default options shown can be overridden by config file or environment 
variables, where provided. Use --show-defaults to see what values would
be used, given the impact of config files / environment variables.
"""
  
  
type
  FlagID = enum
    fidColor, fidNoColor, fidDryRun, fidNoDryRun, fidSilent, fidQuiet,
    fidNormal, fidVerbose, fidTrace, fidCfgFileName, fidCfgSearchPath,
    fidOverwrite, fidNoOverwrite, fidRecursive, fidNoRecursive

  OptParts = (string, string, string)
  OptTable = Table[FlagID, OptParts]

const
  flagPairs: OptTable = {
    fidColor: (fColorShort, fColorLong, colorHelp),
    fidNoColor: (fNoColorShort, fNoColorLong, noColorHelp),
    fidDryRun: (fDryRunShort, fDryRunLong, dryRunHelp),
    fidNoDryRun: (fNoDryRunShort, fNoDryRunLong, noDryRunHelp),
    fidSilent: (fSilentShort, fSilentLong, silentHelp),
    fidQuiet: (fQuietShort, fQuietLong, quietHelp),
    fidNormal: (fNormalShort, fNormalLong, normalHelp),
    fidVerbose: (fVerboseShort, fVerboseLong, verboseHelp),
    fidTrace: (fTraceShort, fTraceLong, traceHelp),
    fidOverwrite: (fOverwriteShort, fOverwriteLong, overwriteHelp),
    fidNoOverwrite: (fNoOverwriteShort, fNoOverwriteLong, noOverwriteHelp),
    fidRecursive: (fRecursiveShort, fRecursiveLong, recursiveHelp),
    fidNoRecursive: (fNoRecursiveShort, fNoRecursiveLong, noRecursiveHelp),
  }.toTable()

  mainOpts = [
    (fCfgFileNameShort, fCfgFileNameLong, cfgFileHelp),
    (fCfgSearchPathShort, fCfgSearchPathLong, cfgSearchHelp)
  ]

  topFlags = [
    fidColor, fidNoColor, fidDryRun, fidNoDryRun, fidSilent, fidQuiet,
    fidNormal, fidVerbose, fidTrace
  ]

  injectFlags = [fidRecursive, fidNoRecursive]
  extractFlags = [fidRecursive, fidNoRecursive]

# When doing option parsing, error when two conflicting flags are given.
proc flagConflict(flag1: FlagID, flag2: FlagID) {.noreturn.} =

  let
    (s1, l1, _) = flagPairs[flag1]
    (s2, l2, _) = flagPairs[flag2]

  error(eConflictFmt.fmt())
  quit()

macro genCmdFlags(fromWhat: static[openarray[FlagID]]): untyped =
  result = newStmtList()

  for flag in fromWhat:
    let (s, l, h) = flagPairs[flag]

    result.add:
      newCall("flag", newLit(s), newLit(l), newLit(false), newLit(h))

template injectCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(insertHelp)
    arg("files", nargs = -1, help = inFilesHelp)

    genCmdFlags(injectFlags)

    run:
      if opts.recursive or opts.noRecursive:
        if opts.recursive and opts.noRecursive:
          flagConflict(fidRecursive, fidNoRecursive)
        elif opts.recursive:
          setRecursive(true)
        else:
          setRecursive(false)
      setArgs(opts.files)      
      setArtifactSearchPath(opts.files)
      runCmdInject()

template extractCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(extractHelp)
    arg("files", nargs = -1, help = outFilesHelp)

    genCmdFlags(extractFlags)

    # for (s, l, h) in injectOpts:
    #   option(s, l, help = h)

    run:
      if opts.recursive or opts.noRecursive:
        if opts.recursive and opts.noRecursive:
          flagConflict(fidRecursive, fidNoRecursive)
        elif opts.recursive:
          setRecursive(true)
        else:
          setRecursive(false)
      setArgs(opts.files)      
      setArtifactSearchPath(opts.files)
      runCmdExtract()

template defaultsCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDefHelp)
    arg("args", nargs = -1, help = dumpFileHelp)            
    run:
      setArgs(opts.args)      
      runCmdDefaults()

template dumpCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDumpHelp)
    arg("args", nargs = -1, help = dumpFileHelp)      
    run:
      setArgs(opts.args)
      runCmdDump(opts.args)

template loadCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showLoadHelp)
    arg("args", nargs = -1, help = loadFileHelp)      
    run:
      setArgs(opts.args)
      runCmdLoad()

template delCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDelHelp)
    arg("args", nargs = -1, help = delFilesHelp)
    run:
      setArgs(opts.args)      
      setArtifactSearchPath(opts.args)
      runCmdDel()

when isMainModule:
  var cmdLine = newParser:
    help(generalHelp)

    for flag in topFlags:
      let (s, l, h) = flagPairs[flag]
      flag(s, l, help = h)

    for (s, l, h) in mainOpts:
      option(s, l, help = h)

    run:
      if opts.color or opts.noColor:
        if opts.color and opts.noColor:
          flagConflict(fidColor, fidNoColor)
        elif opts.color:
          setColor(true)
        else:
          setColor(false)
      if opts.dryRun or opts.noDryRun:
        if opts.dryRun and opts.noDryRun:
          flagConflict(fidDryRun, fidNoDryRun)
        elif opts.dryRun:
          setDryRun(true)
        else:
          setDryRun(false)
      if (opts.silent or opts.quiet or opts.normalOutput or
          opts.verbose or opts.info):
        if opts.silent and opts.quiet:
          flagConflict(fidSilent, fidQuiet)
        elif opts.silent and opts.normalOutput:
          flagConflict(fidSilent, fidNormal)
        elif opts.silent and opts.verbose:
          flagConflict(fidSilent, fidVerbose)
        elif opts.silent and opts.verbose:
          flagConflict(fidSilent, fidTrace)
        elif opts.quiet and opts.normalOutput:
          flagConflict(fidQuiet, fidNormal)
        elif opts.quiet and opts.verbose:
          flagConflict(fidQuiet, fidVerbose)
        elif opts.quiet and opts.verbose:
          flagConflict(fidQuiet, fidTrace)
        elif opts.normalOutput and opts.verbose:
          flagConflict(fidNormal, fidVerbose)
        elif opts.normalOutput and opts.verbose:
          flagConflict(fidNormal, fidTrace)
        elif opts.verbose and opts.verbose:
          flagConflict(fidVerbose, fidTrace)
        elif opts.verbose:
          setLogLevel("trace")
        elif opts.verbose:
          setLogLevel("info")
        elif opts.normalOutput:
          setLogLevel("warn")
        elif opts.quiet:
          setLogLevel("error")
        elif opts.silent:
          setLogLevel("silent")
      if opts.configFileName != "":
        setConfigFileName(opts.configFileName)
      if opts.configSearchPath != "":
        setConfigPath(opts.configSearchPath.split(":"))

    injectCmd("inject", true)
    injectCmd("insert", false)
    injectCmd("ins", false)
    injectCmd("inj", false)
    injectCmd("in", false)
    injectCmd("i", false)    

    extractCmd("extract", true)
    extractCmd("ex", false)
    extractCmd("x", false)

    defaultsCmd("defaults", true)
    defaultsCmd("def", false)
    defaultsCmd("d", false)

    dumpCmd("configDump", true)
    dumpCmd("dump", false)

    loadCmd("configLoad", true)
    loadCmd("load", false)

    delCmd("delete", true)
    delCmd("del", false)

  try:
    cmdLine.run()
    # cmdLine.run() doesn't return, if successful.
    stderr.writeLine(cmdLine.help)
    quit(1)
  except UsageError:
    stderr.writeLine(getCurrentExceptionMsg())
    quit(1)
