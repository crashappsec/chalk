##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

# Note that imports cause topics and plugins to register.
{.warning[UnusedImport]: off.}
import "."/[config, confload, commands, norecurse, sinks,
            attestation_api, util]

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
  loadAttestation()        # attestation.nim
  case getCommandName()    # config.nim
  of "extract":            runCmdExtract(attrGet[seq[string]]("artifact_search_path"))
  of "extract.containers": runCmdExtractContainers()
  of "extract.images":     runCmdExtractImages()
  of "extract.all":        runCmdExtractAll(attrGet[seq[string]]("artifact_search_path"))
  of "insert":             runCmdInsert(attrGet[seq[string]]("artifact_search_path"))
  of "delete":             runCmdDelete(attrGet[seq[string]]("artifact_search_path"))
  of "env":                runCmdEnv()
  of "dump":               runCmdConfDump()
  of "dump.params":        runCmdConfDumpParams()
  of "dump.cache":         runCmdConfDumpCache()
  of "dump.all":           runCmdConfDumpAll()
  of "load":               runCmdConfLoad()
  of "config":             showConfigValues(force = true)
  of "version":            runCmdVersion()
  of "docker":             runCmdDocker(getArgs())
  of "exec":               runCmdExec(getArgs())
  of "setup":              runCmdSetup()
  of "daemon":             runCmdDaemon()
  of "docgen":             runChalkDocGen() # in cmd_help
  of "__.onbuild":         runCmdOnBuild() # in cmd_internal
  else:
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfigValues()
  quitChalk()
