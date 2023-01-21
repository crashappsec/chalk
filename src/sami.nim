## This is the entry point for SAMI.
##
## Here's an overview of what happens:
## 0) Some **internal registration** happens as modules load.  Specifically:
##      a) We register output topics that SAMI uses.
##      b) Plugins register themselves, and any con4m callbacks they support.
## 1) **Arguments** get parsed (but the values are not committed)
## 2) We load in the SAMI **con4m schema**, and validate it. The schema
##    definition lives in `configs/schema.c4m`
## 3) We load in a small **base configuration** that does NOT change, which is
##    in `configs/baseconfig.c4m`. This is fixed, because we don't want people
##    accidentally deleting the I/O setup.
## 4) We load the **embedded configuration**, which shouldn't do much except
##    document the kinds of things people can do. This lives in
##    `configs/defaultconfig.c4m`
## 5) At this point, we **commit** any command-line flags that the embedded
##    configuration allows us to commit. (audit will still report what flags
##    people tried to use, even if they're not allowed).
## 6) Run any **external configuration**, if it exists, as long as the
##    embedded config allows it to run.
## 7) **Audit**, if the embedded configuration asked for it (it does NOT by
##    default, as we don't want to spam people who haven't set up a place for
##    this to go... we don't want it spamming stdout for sure).
## 8) **Dispatch** to the appropriate command, which runs and returns.
## 9) **Publish defaults**, if doing so was requested.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023

import tables, nativesockets, json, strutils, os, options
# Note that importing builtins causes topics to register, and
# importing plugins causes plugins to register.
import nimutils, config, builtins, plugins
import inject, extract, delete, confload, defaults, help

var `selfSami?` = none(SamiDict)

# Tiny commands live in this file. The major ones are broken out.
proc runCmdConfDump() {.inline.} =
  var toDump  = defaultConfig
  var argList = getArgs()

  if `selfSami?`.isSome():
    let selfSami = `selfSami?`.get()

    if selfSami.contains("X_SAMI_CONFIG"):
      toDump   = unpack[string](selfSami["X_SAMI_CONFIG"])

  publish("confdump", toDump)

proc runCmdVersion() =
  var
    rows = @[@["Sami version", getSamiExeVersion()],
             @["Commit ID",    getSamiCommitID()],
             @["Build OS",     hostOS],
             @["Build CPU",    hostCPU],
             @["Build Date",   CompileDate],
             @["Build Time",   CompileTime]]
    t    = samiTableFormatter(2, rows=rows)

  t.setTableBorders(false)
  t.setNoHeaders()

  publish("version", t.render() & "\n")

proc doAudit(commandName: string,
             parsedFlags: TableRef[string, string],
             configFile:  Option[string]) =
  if not getPublishAudit():
    return

  var flagStrs: seq[string] = @[]

  for key, value in parsedFlags:
    if value == "":
      flagStrs.add("--" & key)
    else:
      flagStrs.add("--" & key & "=" & value)

  var preJson  = { "command"    : commandName,
                   "flags"      : flagStrs.join(","),
                   "hostname"   : getHostName(),
                   "config"     : configFile.getOrElse(""),
                   "time"       : $(unixTimeInMs()),
                   "platform"   : getSamiPlatform(),
                 }.toTable()

  publish("audit", $(%* prejson))

when isMainModule:
  var
    parsed:        ArgResult
    done:          bool
    cmdName:       string
    `configFile?`: Option[string]
    flags:         TableRef[string, string]

    cmdLine = newArgSpec(defaultCmd = true).
              addPairedFlag('c', 'C', "color", setColor).
              addPairedFlag('d', 'D', "dry-run", setDryRun).
              addPairedFlag('p', 'P', "publish-defaults", setPublishDefaults).
              addBinaryFlag('h', "help", BinaryCallback(doHelp)).
              addChoiceFlag('l', "log-level", @["verbose", "trace", "info",
                                                "warn", "error", "none"],
                            true,
                            setSamiLogLevel).
              addFlagWithStrArg('f', "config-file", setConfigFile)

  cmdLine.addCommand("insert", ["inject", "ins", "in", "i"]).
            addArgs(callback = setArtifactSearchPath).
            addPairedFlag('r', 'R', "recursive", setRecursive)

  cmdLine.addCommand("extract", ["ex", "e"]).
            addArgs(callback = setArtifactSearchPath).
            addPairedFlag('r', 'R', "recursive", setRecursive)

  cmdLine.addCommand("delete", ["del"]).
            addArgs(callback = setArtifactSearchPath).
            addPairedFlag('r', 'R', "recursive", setRecursive)

  cmdLine.addCommand("defaults", ["def"])
  cmdLine.addCommand("confdump", ["dump"]).addArgs(min = 0, max = 1)
  cmdLine.addCommand("confload", ["load"]).addArgs(min = 1, max = 1)
  cmdLine.addCommand("version", ["vers", "v"])
  cmdLine.addCommand("help", ["h"]).addArgs(min = 0, max = 1)

  try:
    (parsed, done) = cmdLine.mostlyParse(topHasDefault = true)
    cmdName        = getOrElse(parsed.getCurrentCommandName(), "default")
    flags          = parsed.getFlags()
  except:
    error(getCurrentExceptionMsg())
    doHelp()

  if "log-level" in flags:
    # We can't call samiLogLevel yet b/c there's no config object
    # to set overrides on.
    setLogLevel(flags["log-level"])

  if parsed.getSubcommand().isSome():
    setArgs(parsed.getSubcommand().get().getArgs())

  setCommandName(cmdName)

  # Now that we've set argv, we can do our own setup, including
  # loading the base configuration.  This is in config.nim
  loadBaseConfiguration()
  if "log-level" in flags:
    setSamiLogLevel(flags["log-level"])

  # This is in plugin.nim, but can't easily live in our validation
  # code in the previous call, because it would add a cyclic module
  # dependency.  But this is conceptually part of the schema
  # validation... are there any loaded plugins that do NOT show up in
  # the schema?  It also will cause the plugin objects to cache a
  # reference to the con4m configuration info about the plugin (this
  # could easily wait until the plugin first gets used, but if we do
  # that, put it in a once: block).
  validatePlugins()
  # Next, we need to load the embedded configuration, so we load our
  # self-SAMI, if we have one, as loadEmbeddedConfig will check it for
  # the embedded config, and select the default if it isn't there.
  # getSelfExtraction() is in extract.nim; loadEmbeddedConfig is in
  # config.nim
  `selfSami?` = getSelfExtraction()

  let
    configLoaded = loadEmbeddedConfig(`selfSami?`)
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
  if cmdName == "default":
    var `cmd?` = getDefaultCommand()
    if `cmd?`.isSome():
      cmdName = `cmd?`.get()
      setCommandName(cmdName)
      try:
        parsed.applyDefault(cmdName)
      except:
        error(getCurrentExceptionMsg())
        cmdName = "help"
    else:
        error("No valid command provided. See '" & appName & "help'.")
        cmdName = "help"

  if getAllowExternalConfig() and cmdName != "help":
    parsed.commit()  # Now if there is a config file flag we'll take it.
    `configFile?` = loadUserConfigFile(cmdName, `selfSami?`)
  else:
    parsed.commit()

  doAudit(cmdName, flags, `configFile?`)

  case cmdName
  of "insert":
    doInjection()
  of "extract":
    let extractions = doExtraction()
    if extractions.isSome():
      publish("extract", extractions.get())
    else:
      warn("No items extracted")
  of "delete":
    doDelete()
  of "confdump":
    runCmdConfDump()
  of "confload":
    runCmdConfLoad()
  of "defaults":
    discard # Will be handled by showConfig() below.
  of "version":
    runCmdVersion()
  of "help":
    doHelp() # doHelp() exits; it does NOT do a config dump or run the config.
  else:
    unreachable # Unless we add more commands.

  showConfig() # In defaults.
