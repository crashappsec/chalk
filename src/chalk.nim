## This is the entry point for chalk.
##
## Here's an overview of what happens:
## 0) Some **internal registration** happens as modules load.  Specifically:
##      a) We register output topics that chalk uses.
##      b) Plugins register themselves, and any con4m callbacks they support.
## 1) **Arguments** get parsed (but the values are not committed)
## 2) We load in the base chalk configuration (written in con4m).
## 4) We load the **embedded configuration**, which shouldn't do much except
##    document the kinds of things people can do. This lives in
##    `configs/defaultconfig.c4m`
## 5) At this point, we **commit** any command-line flags that the embedded
##    configuration allows us to commit. (audit will still report what flags
##    people tried to use, even if they're not allowed).
## 6) We now nun any **external configuration**, if it exists, as long as the
##    embedded config allows it to run.
## 7) **Audit**, if the embedded configuration asked for it (it does NOT by
##    default, as we don't want to spam people who haven't set up a place for
##    this to go... we don't want it spamming stdout for sure).
## 8) **Dispatch** to the appropriate command, which runs and returns.
## 9) **Publish defaults**, if doing so was requested.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, nativesockets, json, strutils, os, options
# Note that importing builtins causes topics to register, and
# importing plugins causes plugins to register.
import nimutils, types, config, builtins, plugins
import inject, extract, confload, defaults, help

var `selfChalk?` = none(ChalkObj)

# Tiny commands live in this file. The major ones are broken out.
proc runCmdExtraction() {.inline.} =
  let extractions = doExtraction()
  if extractions.isSome(): publish("extract", extractions.get())
  else:                    warn("No items extracted")

proc runCmdConfDump() {.inline.} =
  var
    toDump  = defaultConfig
    argList = getArgs()

  if `selfChalk?`.isSome():
    let selfChalk = `selfChalk?`.get()

    if selfChalk.extract.contains("_CHALK_CONFIG"):
      toDump   = unpack[string](selfChalk.extract["_CHALK_CONFIG"])

  publish("confdump", toDump)

proc runCmdVersion() =
  var
    rows = @[@["Chalk version", getChalkExeVersion()],
             @["Commit ID",     getChalkCommitID()],
             @["Build OS",      hostOS],
             @["Build CPU",     hostCPU],
             @["Build Date",    CompileDate],
             @["Build Time",    CompileTime & " UTC"]]
    t    = chalkTableFormatter(2, rows=rows)

  t.setTableBorders(false)
  t.setNoHeaders()

  publish("version", t.render() & "\n")

proc doAudit(commandName: string,
             parsedFlags: Table[string, string],
             configFile:  Option[string]) =
  if not chalkConfig.getPublishAudit(): return

  var flagStrs: seq[string] = @[]

  for key, value in parsedFlags:
    if value == "": flagStrs.add("--" & key)
    else:           flagStrs.add("--" & key & "=" & value)

  var preJson  = { "command"    : commandName,
                   "flags"      : flagStrs.join(","),
                   "hostname"   : getHostName(),
                   "config"     : configFile.getOrElse(""),
                   "time"       : $(unixTimeInMs()),
                   "platform"   : getChalkPlatform(),
                 }.toTable()

  publish("audit", $(%* prejson))

when isMainModule:
  var
    parsed:        seq[ArgResult]
    cmdName:       string
    `configFile?`: Option[string]
    cmdLine:       CommandSpec

  cmdLine = newCmdLineSpec().
    addYesNoFlag("color", some('c'), some('C'), callback = setColor).
    addYesNoFlag("dry-run", some('d'), some('D'), callback = setDryRun).
    addYesNoFlag("publish-defaults", some('p'), some('P'),
                 callback = setPublishDefaults).
    addBinaryFlag("help", ["h"], callback = BinaryCallback(doHelp)).
    addChoiceFlag("log-level",
                  ["verbose", "trace", "info", "warn", "error", "none"],
                  true, ["l"],  callback = setConsoleLogLevel).
    addFlagWithArg("config-file", ["f"], setConfigFile)

  cmdLine.addCommand("insert", ["inject", "ins", "in", "i"]).
    addArgs(callback = setArtifactSearchPath).
    addFlagWithArg("container-image-id", ["I"], setContainerImageId).
    addFlagWithArg("container-image-name", ["N"], setContainerImageName).
    addYesNoFlag("recursive", some('r'), some('R'), callback = setRecursive)

  cmdLine.addCommand("extract", ["ex", "e"]).
    addArgs(callback = setArtifactSearchPath).
    addYesNoFlag("recursive", some('r'), some('R'), callback = setRecursive)

  cmdLine.addCommand("delete", ["del"], unknownFlagsOk = true).
    addArgs(callback = setArtifactSearchPath).
    addYesNoFlag("recursive", some('r'), some('R'), callback = setRecursive)

  cmdLine.addCommand("defaults", ["def"])
  cmdLine.addCommand("confdump", ["dump"]).addArgs(min = 1)
  cmdLine.addCommand("confload", ["load"]).addArgs(min = 1, max = 1)
  cmdLine.addCommand("version", ["vers", "v"])
  cmdLine.addCommand("entrypoint", noFlags = true).addArgs()
  cmdLine.addCommand("docker", noFlags = true).addArgs()

  try:
    parsed = cmdLine.ambiguousParse(defaultCmd = some(""), runCallbacks = false)
    if len(parsed) == 1:
      cmdName = parsed[0].getCommand()
      setArgs(parsed[0].getArgs(cmdName).get())
    else:
      cmdName = "default"
    setCommandName(cmdName)
  except:
    error(getCurrentExceptionMsg())
    doHelp()

  if "log-level" in parsed[0].flags:
    # We can't call chalkLogLevel yet b/c there's no config object
    # to set overrides on.
    setLogLevel(parsed[0].flags["log-level"])

  # Now that we've set argv, we can do our own setup, including
  # loading the base configuration.  This is in config.nim
  loadBaseConfiguration()
  if "log-level" in parsed[0].flags:
    setConsoleLogLevel(parsed[0].flags["log-level"])
  # Can set items from the command line. Due to our argument design,
  # even if the command is ambiguous it's safe to do this.
  if len(parsed) >= 1: parsed[0].runCallbacks()
  validatePlugins()
  # Next, we need to load the embedded configuration, so we load our
  # self-chalk, if we have any, as loadEmbeddedConfig will check it for
  # the embedded config, and select the default if it isn't there.
  # getSelfExtraction() is in extract.nim; loadEmbeddedConfig is in
  # config.nim
  `selfChalk?` = getSelfExtraction()

  let
    configLoaded = loadEmbeddedConfig(`selfChalk?`)
    appName      = getAppFileName().splitPath().tail

  if not configLoaded and cmdName notin ["load", "help"]:
    error("Default config didn't load. Run '" & appName &
          " load default' to generate a fixed executable.")
    cmdName = "help"

  # We allow the embedded config file to control what happens if no
  # command is specified, particularly, which command should run.  So,
  # if the argument parsing didn't match a command, we had passed in
  # "default" as a command name, and if we had to ask the config file,
  # we now need the answer, so we can dispatch.
  if len(parsed) > 1:
    var `cmd?` = chalkConfig.getDefaultCommand()
    if `cmd?`.isSome():
      cmdName = `cmd?`.get()
      setCommandName(cmdName)
    if len(parsed) > 1:
      error("No valid command provided. See '" & appName & "help'.")
      cmdName = "help"
  if chalkConfig.getAllowExternalConfig() and cmdName != "help":
    `configFile?` = loadUserConfigFile(cmdName)

  doAudit(cmdName, parsed[0].flags, `configFile?`)

  case cmdName
  of "extract":  runCmdExtraction()
  of "insert":   doInjection()
  of "delete":   doInjection(deletion = true)
  of "confdump": runCmdConfDump()
  of "confload": runCmdConfLoad()
  of "defaults": discard # Will be handled by showConfig() below.
  of "version":  runCmdVersion()
  of "docker":   echo "called 'docker " & $(getArgs()) & "'"
  of "help":     doHelp() # noreturn; does NOT do dump or run the config.
  else:          unreachable # Unless we add more commands.

  showConfig() # In defaults.
