## This module implements both individual commands, and includes
## --publish-defaults functionality for other commands.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import config

import commands/[cmd_insert, cmd_extract, cmd_delete, cmd_docker, cmd_exec,
                 cmd_env, cmd_dump, cmd_load, cmd_defaults, cmd_profile,
                 cmd_version, cmd_help]
export cmd_insert, cmd_extract, cmd_delete, cmd_docker, cmd_exec, cmd_env,
       cmd_dump, cmd_load, cmd_defaults, cmd_profile, cmd_version, cmd_help

#% INTERNAL
import commands/cmd_helpdump
export cmd_helpdump
#% END

proc runChalkSubScan*(location: string,
                 cmd:      string,
                 callback: (CollectionCtx) -> void): CollectionCtx =
  # Currently, we always recurse in subscans.
  let
    oldRecursive = chalkConfig.recursive
    oldCmd       = getCommandName()

  setCommandName(cmd)

  try:
    chalkConfig.recursive = true
    result                = pushCollectionCtx(callback)
    case cmd
    # if someone is doing 'docker' recursively, we look
    # at the file system instead of a docker file.
    of "insert", "build": runCmdInsert (@[location])
    of "extract": runCmdExtract(@[location])
    of "delete":  runCmdDelete (@[location])
    else: discard
  finally:
    popCollectionCtx()
    setCommandName(oldCmd)
    chalkConfig.recursive = oldRecursive
