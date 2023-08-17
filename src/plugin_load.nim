## Plugin loading; currently this is only static plugins.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.
# We only need to load plugins that aren't loaded by anything else.

import macros

macro loadPlugins(list: static[openarray[string]]): untyped =
  var
    imports = newNimNode(nnkStmtList)
    loads   = newNimNode(nnkStmtList)

  for item in list:
    loads.add(nnkCall.newTree(newIdentNode("load" & item)))

    let importTree = quote do:
      import plugins/`item`

    imports.add(importTree)

  let loadDecl = quote do:
    proc loadAllPlugins*() =
      `loads`

  result = imports
  result.add(loadDecl)

# Putting `pluginName` in here will cause `loadPluginName()`
# to get called.

loadPlugins(["codecDocker", "codecElf", "codecMacOs", "codecPythonPyc",
             "codecSource", "codecZip", "ciGithub", "ciGitlab", "ciJenkins",
             "conffile", "ecs", "externalTool", "ownerAuthors", "ownerGithub",
             "procfs", "system", "vctlGit"])
