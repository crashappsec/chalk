import resources
import config
import inject
import extract
import plugins

import argparse
import macros
import tables
import strformat


doAdditionalValidation()

proc runCmdDefaults*() {.noreturn, inline.} =
  loadUserConfigFile()
  loadCommandPlugins()
  showConfig() # config.nim
  quit()

proc runCmdInject*() {.noreturn, inline.} =
  loadUserConfigFile()
  loadCommandPlugins()  
  doInjection() # inject.nim
  quit()

proc runCmdExtract*() {.noreturn, inline.} =
  loadUserConfigFile()
  doExtraction(onBehalfOfInjection = false) # extract.nim
  quit()

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

  injectOpts = [
    (fOutputFileShort, fOutputFileLong, outFileHelp),
    (fOutputDirShort, fOutputDirLong, outDirHelp),
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

    for (s, l, h) in injectOpts:
      option(s, l, help = h)

    run:
      if opts.recursive or opts.noRecursive:
        if opts.recursive and opts.noRecursive:
          flagConflict(fidRecursive, fidNoRecursive)
        elif opts.recursive:
          setRecursive(true)
        else:
          setRecursive(false)
      if opts.outputFile != "":
        setOutputFile(opts.outputFile)
      if opts.outputDir != "":
        setOutputDir(opts.outputDir)
      setArtifactSearchPath(opts.files)
      runCmdExtract()

template defaultsCmd(cmd: string, primary: bool) =
  command(cmd):
    if primary:
      help(showDefHelp)
    run:
      runCmdDefaults()  
  
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

    injectCmd(cmdNameInject1, true)
    injectCmd(cmdNameInject2, false)
    injectCmd(cmdNameInject3, false)
    injectCmd(cmdNameInject4, false)
    injectCmd(cmdNameInject5, false)

    extractCmd(cmdNameExtract1, true)
    extractCmd(cmdNameExtract2, false)
    extractCmd(cmdNameExtract3, false)

    defaultsCmd(cmdNameDefaults1, true)
    defaultsCmd(cmdNameDefaults2, false)
    defaultsCmd(cmdNameDefaults3, false)

  try:
    cmdLine.run()
    # cmdLine.run() doesn't return, if successful.
    stderr.writeLine(cmdLine.help)
    quit(1)
  except UsageError:
    stderr.writeLine(getCurrentExceptionMsg())
    quit(1)

