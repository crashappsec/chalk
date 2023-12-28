##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

# Note that imports cause topics and plugins to register.
{.warning[UnusedImport]: off.}
import config, confload, commands, norecurse, sinks, docker_base,
       attestation, util

when isMainModule:
  setupSignalHandlers() # util.nim
  setupTerminal()       # util.nim
  ioSetup()             # sinks.nim
  loadAllConfigs()      # confload.nim
  recursionCheck()      # norecurse.nim
  otherSetupTasks()     # util.nim
  # Wait for this warning until after configs load.
  if not canSelfInject:
    warn("No working codec is available for the native executable type")

  if passedHelpFlag:
    runChalkHelp(getCommandName()) # no return; in cmd_help.nim

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
  of "dump.params":        runCmdConfDumpParams()
  of "dump.cache":         runCmdConfDumpCache()
  of "load":               runCmdConfLoad()
  of "config":             showConfigValues(force = true)
  of "version":            runCmdVersion()
  of "docker":             runCmdDocker(getArgs())
  of "exec":               runCmdExec(getArgs())
  of "docgen":             runChalkDocGen() # in cmd_help
  else:
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfigValues()
  quitChalk()
