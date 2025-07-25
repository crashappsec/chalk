##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Plugin loading; currently this is only static plugins.
##
## We only need to load plugins that aren't loaded by anything else.

import std/macros

macro loadPlugins(list: static[openArray[string]]): untyped =
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

loadPlugins([
  "awsEcs",
  "awsLambda",
  "ciCodeBuild",
  "ciGithub",
  "ciGitlab",
  "ciJenkins",
  "cloudMetadata",
  "codecCerts",
  "codecDocker",
  "codecElf",
  "codecFallbackElf",
  "codecMacOs",
  "codecPythonPyc",
  "codecSource",
  "codecZip",
  "conffile",
  "externalTool",
  "network",
  "ownerAuthors",
  "ownerGithub",
  "procfs",
  "system",
  "vctlGit",
])
