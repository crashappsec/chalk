import resources
import config
import inject
import extract
import plugins

import argparse
import macros except error
import tables
import strformat
import nimutils/box
import con4m/[types, builtins]

# This "builtin" call for con4m doesn't need to be available until
# user configurations load, but let's be sure to do it before that
# happens.  First we define the function here, and next we'll register
# it.
var cmdInject = some(pack(false))

proc getInjecting*(args: seq[Box],
                   unused1: Con4mScope,
                   unused2: VarStack,
                   unused3: Con4mScope): Option[Box] =
    return cmdInject


# getConfigState() is defined in config.nim, and basically
# just exports a variable that is auto-generated for us when we
# initialize con4m (also in config.nim).

let ctxSamiConf = getConfigState()
ctxSamiConf.newBuiltIn("injecting", getInjecting, "f() -> bool")

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
  showConfig() # config.nim
  quit()

proc runCmdInject() {.noreturn, inline.} =
  # This needs to be set before we load any user-level configuration
  # file, for the sake of the "injecting()" builtin (above).  Note: we
  # cannot use that builtin in the base configuration, since we run
  # that before we set up any command-line arguments; it would return
  # 'false' for us always, no matter what the user supplies.
  cmdInject = some(pack(true))
  loadUserConfigFile(getSelfExtraction())
  loadCommandPlugins()
  doInjection() # inject.nim
  quit()

proc runCmdExtract() {.noreturn, inline.} =
  loadUserConfigFile(getSelfExtraction())
  doExtraction(onBehalfOfInjection = false) # extract.nim
  quit()

proc runCmdDump() {.noreturn, inline.} =
  handleConfigDump(getSelfExtraction())

proc runCmdLoad() {.noreturn, inline.} =
  # The fact that we're injecting into ourself will be special-cased
  # in the injection workflow.
  let
    selfSami = getSelfExtraction()
    args = getArtifactSearchPath()
    
  quitIfCantChangeEmbeddedConfig(selfSami)
  if len(args) != 1:
    error("configLoad requires either a file name or 'default'")
    quit()

  setupSelfInjection(args[0])
  
  runCmdInject() 

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

  fatal(eConflictFmt.fmt())

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
      setArtifactSearchPath(opts.files)
      runCmdExtract()

template defaultsCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDefHelp)
    run:
      runCmdDefaults()

template dumpCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDumpHelp)
    run:
      runCmdDump()

template loadCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showLoadHelp)
    run:
      runCmdLoad()

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
          opts.verbose or opts.trace):
        if opts.silent and opts.quiet:
          flagConflict(fidSilent, fidQuiet)
        elif opts.silent and opts.normalOutput:
          flagConflict(fidSilent, fidNormal)
        elif opts.silent and opts.verbose:
          flagConflict(fidSilent, fidVerbose)
        elif opts.silent and opts.trace:
          flagConflict(fidSilent, fidTrace)
        elif opts.quiet and opts.normalOutput:
          flagConflict(fidQuiet, fidNormal)
        elif opts.quiet and opts.verbose:
          flagConflict(fidQuiet, fidVerbose)
        elif opts.quiet and opts.trace:
          flagConflict(fidQuiet, fidTrace)
        elif opts.normalOutput and opts.verbose:
          flagConflict(fidNormal, fidVerbose)
        elif opts.normalOutput and opts.trace:
          flagConflict(fidNormal, fidTrace)
        elif opts.verbose and opts.trace:
          flagConflict(fidVerbose, fidTrace)
        elif opts.trace:
          setLogLevel("trace")
        elif opts.verbose:
          setLogLevel("verbose")
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

  try:
    cmdLine.run()
    # cmdLine.run() doesn't return, if successful.
    stderr.writeLine(cmdLine.help)
    quit(1)
  except UsageError:
    stderr.writeLine(getCurrentExceptionMsg())
    quit(1)

