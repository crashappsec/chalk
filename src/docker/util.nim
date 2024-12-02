##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[unicode]
import ".."/[config, util]

template withAtomicAdds*(ctx: DockerInvocation, code: untyped) =
  withAtomicVar(ctx.addedPlatform):
    withAtomicVar(ctx.addedInstructions):
      code

proc isValidEnvVarName*(s: string): bool =
  if len(s) == 0 or (s[0] >= '0' and s[0] <= '9'):
    return false

  for ch in s:
    if ch.isAlphaNumeric() or ch == '_':
      continue
    return false

  return true

var labelPrefix: string
proc formatLabelKey(s: string): string =
  once:
    labelPrefix = attrGet[string]("docker.label_prefix")

  result = labelPrefix

  if not labelPrefix.endsWith('.'):
    result &= "."

  result &= s

  result = result.toLowerAscii()
  result = result.replace("_", "-")
  result = result.replace("$", "_")

type SkipLabel = object of CatchableError

proc formatLabelValue(v: string): string =
  if unicode.strip(v).len() == 0:
    raise newException(SkipLabel, "empty label")
  if v.startswith('"') and v[^1] == '"':
    if len(v) > 1:
      return v
    else:
      raise newException(SkipLabel, "empty label")
  else:
    return escapeJson(v)

proc formatLabel(name: string, value: string, prefix = ""): string =
  result &= prefix & formatLabelKey(name) & "=" & formatLabelValue(value)
  trace("docker: formatting label: " & result)

proc addLabelArg(self: var seq[string], name: string, value: string) =
  try:
    let label = formatLabel(name, value)
    self.add("--label")
    self.add(label)
  except SkipLabel:
    discard

proc addLabelCmd*(self: var seq[string], name: string, value: string, prefix = "LABEL ") =
  try:
    let label = formatLabel(name, value, prefix = prefix)
    self.add(label)
  except SkipLabel:
    discard

proc addLabelArgs*(self: var seq[string], labels: TableRef[string, string]) =
  for k, v in labels:
    self.addLabelArg(k, v)

proc addLabelArgs*(self: var seq[string], labels: ChalkDict) =
  for k, v in labels:
    self.addLabelArg(k, v.boxToJson())

proc addLabelCmds*(self: var seq[string], labels: TableRef[string, string]) =
  for k, v in labels:
    self.addLabelCmd(k, v)

proc addLabelCmds*(self: var seq[string], labels: ChalkDict) =
  for k, v in labels:
    self.addLabelCmd(k, v.boxToJson())

proc formatChalkExec*(args: JsonNode = newJArray()): string =
  var
    arr  = `%*`(["/chalk", "exec"])
    args =
      if args == nil or args == %(@[""]):
        newJArray()
      else:
        args
  if len(args) > 0:
    if unicode.strip(args[0].getStr()) == "":
      raise newException(
        ValueError,
        "invalid first element in " & $args &
        " - has to be valid executable command"
      )
    arr.add(`%`("--exec-command-name"))
    arr.add(args[0])
  arr.add(`%`("--"))
  if len(args) > 1:
    arr &= args[1..^1]
  return $(arr)

proc getChalkKey*(chalk: ChalkObj, k: string): string =
  if len(k) == 1:
    warn("docker: " & k & ": Invalid; key to pull into ENV var must not be empty.")
    return ""
  let key = k[1 .. ^1]

  if key.startsWith("_"):
    raise newException(KeyError, "Invalid key; cannot use run-time keys, only chalk-time keys.")

  if key notin getContents(attrGetObject("keyspec")):
    raise newException(KeyError, "Invalid for env var; Chalk key doesn't exist.")

  if key in hostInfo:
    return $(hostInfo[key])

  if key in chalk.collectedData:
    return $(chalk.collectedData[key])

  raise newException(KeyError, "key could not be collected. Skipping environment variable.")

proc getValue*(secret: DockerSecret): string =
  if secret.src != "":
    return tryToLoadFile(secret.src)
  return ""
