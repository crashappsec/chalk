import tables, nativesockets, json, strutils, os, options
import nimutils, config, builtins, plugins
import inject, extract, delete, confload, defaults, help

# When we import things above, a few modules do some setup, like
# plugins register. But nothing meaningful yet... 
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
  
    cmdLine = newArgSpec(defaultCmd = true).
              addPairedFlag('c', 'C', "color", setColor).
              addPairedFlag('d', 'D', "dry-run", setDryRun).
              addPairedFlag('p', 'P', "publish-defaults", setPublishDefaults).
              addBinaryFlag('h', "help", BinaryCallback(doHelp)).
              addChoiceFlag('l', "log-level", @["verbose", "trace", "info",
                                                "warn", "error", "none"],
                            true,
                            setlogLevel).
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
  except:
    error(getCurrentExceptionMsg())
    doHelp()

  if parsed.getSubcommand().isSome():
    setArgs(parsed.getSubcommand().get().getArgs())
    
  setCommandName(cmdName)
  
  # Now that we've set argv, we can do our own setup, including
  # loading the base configuration.
  loadBaseConfiguration()
  doAdditionalValidation()
  validatePlugins()
  
  # Let's check our own executable for a self-SAMI.
  `selfSami?` = getSelfExtraction()
    
  let
    configLoaded = loadEmbeddedConfig(`selfSami?`)
    appName      = getAppFileName().splitPath().tail

  if not configLoaded and cmdName notin ["load", "help"]:
    error("Default config didn't load. Run '" & appName &
          " load default' to generate a fixed executable.")
    cmdName = "help"

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

  doAudit(cmdName, parsed.getFlags(), `configFile?`)
  
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

  
