## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# At compile time, this will generate c4autoconf if the file doesn't
# exist, or if the spec file has a newer timestamp.  We do this before
# any submodule imports it.

static:
  echo staticexec("if test \\! c4autoconf.nim -nt configs/chalk.c42spec; " &
                  "then con4m gen configs/chalk.c42spec --language=nim " &
                  "--output-file=c4autoconf.nim; fi")

# Note that importing builtins causes topics to register, and
# importing plugins causes plugins to register.
import config, builtins, commands, plugins

when isMainModule:
  loadAllConfigs()
  setupDefaultLogConfigs()
  case getCommandName()
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
    runChalkHelp(getCommandName()) # noreturn, will not show config.

  showConfig()
