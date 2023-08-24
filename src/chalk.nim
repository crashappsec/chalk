## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# Note that imports cause topics and plugins to register.
{.warning[UnusedImport]: off.}
import config, confload, commands, jitso, norecurse, sinks, docker_base,
       attestation, util

when isMainModule:
  setupSignalHandlers() # util.nim
  addDefaultSinks()     # nimutils/sinks.nim
  loadAllConfigs()      # config.nim
  recursionCheck()      # norecurse.nim
  setupManagedTemp()    # util.nim
  # Wait for this warning until after configs load.
  if not canSelfInject:
    warn("No working codec is available for the native executable type")

  if passedHelpFlag:
    showCommandHelp() # no return; in cmd_help.nim

  setupDefaultLogConfigs() # src/sinks.nim
  checkSetupStatus()       # attestation.nim
  case getCommandName()    # config.nim
  of "extract":            runCmdExtract(chalkConfig.getArtifactSearchPath())
  of "extract.containers": runCmdExtractContainers()
  of "extract.images":     runCmdExtractImages()
  of "extract.all":        runCmdExtractAll(chalkConfig.getArtifactSearchPath())
  of "insert":             runCmdInsert(chalkConfig.getArtifactSearchPath())
  of "delete":             runCmdDelete(chalkConfig.getArtifactSearchPath())
  of "env":                runCmdEnv()
  of "dump":               runCmdConfDump()
  of "load":               runCmdConfLoad()
  of "defaults":           showConfig(force = true)
  of "version":            runCmdVersion()
  of "docker":             runCmdDocker(getArgs())
  of "profile":            runCmdProfile(getArgs())
  of "exec":               runCmdExec(getArgs())
  of "setup":              runCmdSetup(gen=true, load=true)
  of "setup.gen":          runCmdSetup(gen=true, load=false)
  of "setup.load":         runCmdSetup(gen=false, load=true)
  #% INTERNAL
  of "rawattrs":
    let runtime = getChalkRuntime()
    echo parseJson(runtime.attrs.scopeToJson()).pretty()
    quit(1)
  of "rawspec":
    let runtime = getValidationRuntime()
    echo parseJson(runtime.attrs.scopeToJson()).pretty()
    quit(1)
  of "helpdump":           runCmdHelpDump()
  #% END
  else:
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfig()
  quitChalk()
