##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  types,
  utils/json,
  utils/strings,
  utils/toml,
]
import "."/[
  exe,
  inspect,
]

proc getBuilderNodesInfo*(ctx: DockerInvocation): TableRef[string, string] =
  result = newTable[string, string]()
  var
    foundNodes = false
    name       = ""
  for line in ctx.getBuilderInfo().splitLines():
    let lower = line.toLower()
    if lower.startsWith("driver:"):
      let driver = line.splitWhitespace()[^1]
      if driver != "docker-container":
        trace("docker: unsupported buildx builder driver: " & driver)
        return
    if lower.startsWith("nodes:"):
      foundNodes = true
      continue
    if not foundNodes:
      continue
    if lower.startsWith("name:"):
      name = line.splitWhitespace()[^1]
      result[name] = ""
    result[name] &= line & "\n"

proc containerNameForBuilderNode*(node: string): string =
  # ideally we can query the namespaces however they are not exposed
  # via docker info output and are only stored in the buildx config files
  # which we cant read until we know the namespaces
  # TODO search through all running containers if the default namespace is not found
  return "buildx_buildkit_" & node

var nodeFiles = newTable[string, string]()
proc readBuilderNodeFile*(ctx: DockerInvocation, node: string, path: string): string =
  let key = node & ":" & path
  if key in nodeFiles:
    return nodeFiles[key]
  let
    container = containerNameForBuilderNode(node)
    output    = runDockerGetEverything(
      @[
        "exec",
        container,
        "cat",
        path,
      ],
      silent = false,
    )
  if output.exitCode != 0:
    raise newException(ValueError, "could not read buildx node's " & container & " " & path)
  result = output.stdout
  nodeFiles[key] = result

iterator iterBuilderNodesConfigs*(ctx: DockerInvocation): tuple[name: string, config: JsonNode] =
  for name, _ in ctx.getBuilderNodesInfo():
    try:
      let
        container  = containerNameForBuilderNode(name)
        config     = inspectContainerJson(container){"Config"}
        entrypoint = config{"Entrypoint"}
        cmd        = config{"Cmd"}
        args       = (entrypoint & cmd).getStrElems()
      con4mRuntime.addStartGetOpts("buildkit.getopts", args = args).run()
      let flags    = con4mRuntime.getFlags()
      if "config" notin flags:
        trace("docker: " & name & " builder node is not using custom configuration. using empty default config")
        yield (name, newJObject())
      else:
        let
          configs  = unpack[seq[string]](flags["config"].getValue())
          toml     = ctx.readBuilderNodeFile(name, configs[0])
          config   = parsetoml.parseString(toml).toJson().fromTomlJson()
        yield (name, config)
    except:
      trace("docker: could not load toml for buildx node " & name & " due to: " & getCurrentExceptionMsg())
      continue

proc getBuilderNodesConfigs*(ctx: DockerInvocation): TableRef[string, JsonNode] =
  result = newTable[string, JsonNode]()
  for name, config in ctx.iterBuilderNodesConfigs():
    result[name] = config
