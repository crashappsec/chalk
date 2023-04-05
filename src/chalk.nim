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

# At compile time, this will generate c4autoconf if the file doesn't
# exist, or if the spec file has a newer timestamp.  We do this before
# any submodule imports it.

static:
  echo staticexec("if test \\! c4autoconf.nim -nt configs/chalk.c42spec; " &
                  "then con4m spec configs/chalk.c42spec --language=nim " &
                  "--output-file=c4autoconf.nim; fi")

# Note that importing builtins causes topics to register, and
# importing plugins causes plugins to register.
import tables, nativesockets, os, options, config, builtins, commands, collect


# Since these are system keys, we are the only one able to write them,
# and it's easier to do it directly here than in the system plugin.
proc stashCommandlineInfo(parsedFlags: Table[string, string],
                          configFile:  Option[string]) =
  var flagStrs: seq[string] = @[]

  for key, value in parsedFlags:
    if value == "": flagStrs.add("--" & key)
    else:           flagStrs.add("--" & key & "=" & value)

  hostInfo["_OP_CMD_FLAGS"] = pack(flagStrs)

  if configFile.isSome():
    hostInfo["_OP_CONFIG"]  = pack(configFile.get())

when isMainModule:
  var
    parsed:        seq[ArgResult]
    cmdName:       string
    `configFile?`: Option[string]
    cmdLine:       CommandSpec

  cmdLine = newCmdLineSpec().
    addYesNoFlag("color", some('c'), some('C'), callback = setColor).
    addBinaryFlag("help", ["h"], callback = BinaryCallback(runCmdHelp)).
    addChoiceFlag("log-level",
                  ["verbose", "trace", "info", "warn", "error", "none"],
                  true, ["l"],  callback = setConsoleLogLevel).
    addFlagWithArg("config-file", ["f"], setConfigFile).
    addFlagWithArg("disable-profile", [], callback = disableProfile).
    addFlagWithArg("disable-report", [], callback = disableReport).
    addFlagWithArg("disable-plugin", [], callback = disablePlugin).
    addFlagWithArg("disable-tool",   [], callback = disableTool).
    addFlagWithArg("enable-profile", [], callback = enableProfile).
    addFlagWithArg("enable-report",  [], callback = enableReport).
    addFlagWithArg("enable-plugin",  [], callback = enablePlugin).
    addFlagWithArg("enable-tool",    [], callback = enableTool).
    addFlagWithArg("report-cache-file", [], callback = setReportCacheLocation).
    addYesNoFlag("publish-defaults", callback = setPublishDefaults).
    addYesNoFlag("default-sbom",     callback = setLoadSbomTools).
    addYesNoFlag("default-sast",     callback = setLoadSastTools).
    addYesNoFlag("default-sign",     callback = setLoadDefaultSigning).
    addYesNoFlag("use-report-cache", callback = setUseReportCache)

  cmdLine.addCommand("insert", ["inject", "ins", "in", "i"]).
    addArgs(callback = setArtifactSearchPath).
    addFlagWithArg("container-image-id", ["I"], setContainerImageId).
    addFlagWithArg("container-image-name", ["N"], setContainerImageName).
    addYesNoFlag("virtual", some('v'), some('V'), callback = setVirtualChalk).
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

  let helpCmd = cmdLine.addCommand("help", ["h"],
                                   unknownFlagsOk = true,
                                   subOptional=true).addArgs()
  helpCmd.addCommand("key", ["keys"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("keyspec", ["keyspecs"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("profile", ["profiles"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("tool", ["tools"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("plugin", ["plugins"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("sink", ["sinks"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("outconf", ["outconf"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("report", ["reports", "custom_report", "custom_reports"],
                     unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("sast", unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("sbom", ["sboms"], unknownFlagsOk = true).addArgs()
  helpCmd.addCommand("topics", unknownFlagsOk = true).addArgs()

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
    runCmdHelp()

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
  loadOptionalConfigurations()
  # Next, we need to load the embedded configuration, so we load our
  # self-chalk, if we have any, as loadEmbeddedConfig will check it for
  # the embedded config, and select the default if it isn't there.
  # getSelfExtraction() is in collect.nim; loadEmbeddedConfig is in
  # config.nim.
  #
  # We call this for config to make sure it has no unneeded
  # dependencies.
  let
    configLoaded = loadEmbeddedConfig(getSelfExtraction())
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
  if chalkConfig.getAllowExternalConfig() and cmdName != "help":
    `configFile?` = loadUserConfigFile(cmdName)
  stashCommandLineInfo(parsed[0].flags, `configFile?`)
  setupDefaultLogConfigs()

  case cmdName
  of "extract":    runCmdExtract()
  of "insert":     runCmdInsert()
  of "delete":     runCmdDelete()
  of "confdump":   runCmdConfDump()
  of "confload":   runCmdConfLoad()
  of "defaults":   showConfig(force = true)
  of "version":    runCmdVersion()
  of "docker":     echo "called 'docker " & $(getArgs()) & "'"
  of "entrypoint": echo "entry point."
  else:
    runCmdHelp(cmdName) # noreturn, will not show config.

  showConfig()