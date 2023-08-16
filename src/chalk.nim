## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# Note that imports cause topics and plugins to register.
{.warning[UnusedImport]: off.}
import config, confload, commands, jitso, norecurse, sinks, docker_base,
       attestation, util

when isMainModule:
  addDefaultSinks()
  loadAllConfigs()
  recursionCheck()
  # Wait for this warning until after configs load.
  if not canSelfInject:
    warn("We have no codec for this platform's native executable type")
  setupDefaultLogConfigs()
  checkSetupStatus()
  setDockerExeLocation()
  case getCommandName()
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
  of "helpdump":           runCmdHelpDump()
  #% END
  else:
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfig()
  quitChalk()
