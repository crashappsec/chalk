## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# At compile time, this will generate c4autoconf if the file doesn't
# exist, or if the spec file has a newer timestamp.  We do this before
# any submodule imports it.

static:
  echo "Running dependency test on chalk.c42spec"
  echo staticexec("if test \\! c4autoconf.nim -nt configs/chalk.c42spec; " &
                     "then echo 'Config file schema changed. Regenerating " &
                     "c4autoconf.nim.' ; con4m gen configs/chalk.c42spec " &
                     "--language=nim --output-file=c4autoconf.nim; else " &
                     "echo No change to chalk.c42spec; fi")

# Note that importing builtins causes topics to register, and
# importing plugins causes plugins to register.
{.warning[UnusedImport]: off.}
import config, builtins, commands, plugins, strutils, jitso

when isMainModule:
  loadAllConfigs()
  # Wait for this warning until after configs load.
  if not canSelfInject:
    warn("We have no codec for this platform's native executable type")
  setupDefaultLogConfigs()
  case getCommandName()
  of "extract":        runCmdExtract(chalkConfig.getArtifactSearchPath())
  of "insert":         runCmdInsert(chalkConfig.getArtifactSearchPath())
  of "delete":         runCmdDelete(chalkConfig.getArtifactSearchPath())
  of "env":            runCmdEnv()
  of "dump":           runCmdConfDump()
  of "load":           runCmdConfLoad()
  of "defaults":       showConfig(force = true)
  of "version":        runCmdVersion()
  of "docker":         runCmdDocker()
  of "profile":        runCmdProfile(getArgs())
  of "exec":           runCmdExec(getArgs())
  #% INTERNAL
  of "helpdump":       runCmdHelpDump()
  of "entrypoint":     echo "entry point."
  #% END
  of "extract.containers":
    runCmdExtractContainers(chalkConfig.getArtifactSearchPath())
  else:
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfig()
