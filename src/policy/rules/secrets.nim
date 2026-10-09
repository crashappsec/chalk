##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.secrets`: report secrets found in the local build context by
## trufflehog. See docs/design-build-policy.md for the semantics.
##
## The rule runs its own trufflehog `filesystem` scan of every context
## directory instead of reusing `SECRET_SCANNER`: the tool plugin scans the
## git repository containing the first context, in `git` mode when it can,
## which reads committed history (secrets since removed) and skips untracked
## or ignored files (e.g. a `.env`) that are sent to docker, and a failed
## scan is indistinguishable from a clean one there. For the same reasons it
## does not run the tool through policy/tools.nim (`runTool` uses the tool's
## own arguments and `produce_keys`), only reusing its install and location
## callbacks.
##
## Secret values never leave this module: only the detector, file, line and
## verification status of each result are kept.

import std/[
  json,
  os,
  sets,
  strutils,
  tables,
]
import "../.."/[
  config,
  types,
  utils/files,
]
from "../.."/docker/tar import isExcluded, isValidPattern
import ".."/[
  api,
  configuration,
  helpers,
]

const
  ruleName    = "secrets"
  maxFindings = 100
  # trufflehog exits with 183 when `--fail` is set and it found results
  # https://github.com/trufflesecurity/trufflehog#exit-codes
  trufflehogFoundExit = 183
  # exit codes of `timeout`, see `with_timeout` in base_callbacks.c4m
  timeoutExits = [124, 137]

type
  SecretsConfig* = object
    verify*:          bool
    verifiedOnly*:    bool
    detectors*:       seq[string] # lowercase, empty for all
    ignoreDetectors*: seq[string] # lowercase
    excludePaths*:    seq[string] # .dockerignore syntax
    checkPush*:       bool
    message*:         string

  SecretResult* = object
    ## one trufflehog result, without the secret
    detector*:          string
    file*:              string # absolute
    line*:              int
    commit*:            string # git mode only
    verified*:          bool
    verificationError*: bool
    rotationGuide*:     string

const
  secretsJsonFields = [
    PolicyJsonField(name: "enabled",          kind: JBool),
    PolicyJsonField(name: "verify",           kind: JBool),
    PolicyJsonField(name: "verified_only",    kind: JBool),
    PolicyJsonField(name: "detectors",        kind: JArray),
    PolicyJsonField(name: "ignore_detectors", kind: JArray),
    PolicyJsonField(name: "exclude_paths",    kind: JArray),
    PolicyJsonField(name: "check_push",       kind: JBool),
    PolicyJsonField(name: "message",          kind: JString),
  ]

proc validateExcludePaths(patterns: seq[string], path: string) =
  for p in patterns:
    if p.startsWith('!'):
      # a negation could re-include files .dockerignore keeps out of the context
      raise newException(ValueError, path & " entries cannot start with '!': " & p)
    if not p.isValidPattern():
      raise newException(ValueError, path & " has an invalid pattern: " & p)

proc validateSettings(verify, verifiedOnly: bool, path: string) =
  # without verification nothing is verified, so every secret would pass
  if not verify and verifiedOnly:
    raise newException(ValueError, path & "verify = false requires " &
                                   path & "verified_only = false")

proc validateSecretsJson(node: JsonNode, path: string) =
  node.validateFields(secretsJsonFields, path)
  for name in ["detectors", "ignore_detectors", "exclude_paths"]:
    for entry in node{name}.getElems():
      if entry.kind != JString:
        raise newException(ValueError, path & name & " entries must be strings")
  var excludes: seq[string]
  for entry in node{"exclude_paths"}.getElems():
    excludes.add(entry.getStr())
  excludes.validateExcludePaths(path & "exclude_paths")
  validateSettings(node{"verify"}.getBool(true),
                   node{"verified_only"}.getBool(true),
                   path)

registerPolicyJsonSection(ruleName, validateSecretsJson)

proc lowered(items: seq[string]): seq[string] =
  for item in items:
    result.add(item.strip().toLowerAscii())

proc loadSecretsConfig*(): Option[SecretsConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(SecretsConfig)
  let settings = SecretsConfig(
    verify:          policyBoolSetting([ruleName, "verify"], true),
    verifiedOnly:    policyBoolSetting([ruleName, "verified_only"], true),
    detectors:       policyStringsSetting([ruleName, "detectors"]).lowered(),
    ignoreDetectors: policyStringsSetting([ruleName, "ignore_detectors"]).lowered(),
    excludePaths:    policyStringsSetting([ruleName, "exclude_paths"]),
    checkPush:       policyBoolSetting([ruleName, "check_push"], false),
    message:         policyStringSetting([ruleName, "message"], ""),
  )
  settings.excludePaths.validateExcludePaths("policy.secrets.exclude_paths")
  validateSettings(settings.verify, settings.verifiedOnly, "policy.secrets.")
  return some(settings)

proc toSecretResult(node: JsonNode): Option[SecretResult] =
  ## `none` for results that are not about a file
  if node.kind != JObject:
    return none(SecretResult)
  let data = node{"SourceMetadata", "Data"}
  var source = data{"Filesystem"}
  var commit = ""
  if source == nil:
    source = data{"Git"}
    commit = source{"commit"}.getStr()
  if source == nil or source.kind != JObject or source{"file"}.getStr() == "":
    return none(SecretResult)
  var guide = node{"ExtraData", "rotation_guide"}.getStr()
  if not guide.startsWith("https://"):
    guide = ""
  some(SecretResult(
    detector:          node{"DetectorName"}.getStr("unknown"),
    file:              source{"file"}.getStr(),
    line:              source{"line"}.getInt(),
    commit:            commit,
    verified:          node{"Verified"}.getBool(),
    verificationError: node{"VerificationError"}.getStr() != "",
    rotationGuide:     guide,
  ))

proc parseTrufflehogOutput*(output: string): seq[SecretResult] =
  ## Parses trufflehog `--json` output (one JSON object per line).
  for line in output.splitLines():
    let text = line.strip()
    if not text.startsWith("{"):
      continue
    var node: JsonNode
    try:
      node = parseJson(text)
    except CatchableError:
      # the line holds the secret, so it is never part of the message
      raise newException(ValueError, "trufflehog returned invalid JSON")
    let r = node.toSecretResult()
    if r.isSome():
      result.add(r.get())

proc markSecretResults*(mark: ChalkDict): seq[SecretResult] =
  ## trufflehog results recorded in a chalk mark's `SECRET_SCANNER`
  ## (see secretscannerconfig.c4m), which never hold the secret itself
  if "SECRET_SCANNER" notin mark:
    return
  let scanners = parseJson(mark["SECRET_SCANNER"].boxToJson())
  let items = scanners{"trufflehog"}
  if items == nil:
    return
  var nodes: seq[JsonNode]
  case items.kind
  of JArray:
    nodes = items.getElems()
  of JObject:
    # canonicalized form, keyed by hash
    for _, item in items.pairs():
      nodes.add(item)
  else:
    raise newException(ValueError, "SECRET_SCANNER.trufflehog has an unexpected type")
  for node in nodes:
    let r = node.toSecretResult()
    if r.isSome():
      result.add(r.get())

proc severity*(self: SecretResult): string =
  if self.verified:
    "verified"
  elif self.verificationError:
    "unknown"
  else:
    "unverified"

proc parseDockerignore(text: string): seq[string] =
  for line in text.splitLines():
    let p = line.strip()
    if p.len == 0 or p.startsWith('#'):
      continue
    if p.startsWith('!'):
      result.add('!' & p[1 .. ^1].strip(trailing = false, chars = {'/'}))
    else:
      result.add(p.strip(trailing = false, chars = {'/'}))

proc readDockerignore*(dir: string, dockerfilePath = ""): seq[string] =
  ## Patterns docker applies to context `dir`: `<Dockerfile>.dockerignore`
  ## next to the Dockerfile when it exists, else `<dir>/.dockerignore`
  ## https://docs.docker.com/build/concepts/context/#dockerignore-files
  if dockerfilePath != "":
    let specific = dockerfilePath & ".dockerignore"
    if fileExists(specific):
      return readFile(specific).parseDockerignore()
  let path = dir / ".dockerignore"
  if fileExists(path):
    return readFile(path).parseDockerignore()

proc reason(settings: SecretsConfig, r: SecretResult, where: string): string =
  result =
    case r.severity()
    of "verified":   "verified " & r.detector & " secret " & where
    of "unknown":    r.detector & " secret " & where & " could not be verified"
    else:            "unverified " & r.detector & " secret " & where & " (may be a false positive)"
  if r.commit != "":
    result &= " (commit " & r.commit[0 ..< min(12, len(r.commit))] & ")"
  if r.rotationGuide != "":
    result &= ". Rotate it: " & r.rotationGuide
  if settings.message != "":
    result &= ". " & settings.message

proc findingKind(settings: SecretsConfig, r: SecretResult): string =
  ## empty when the result is not reported
  let detector = r.detector.toLowerAscii()
  if len(settings.detectors) > 0 and detector notin settings.detectors:
    return ""
  if detector in settings.ignoreDetectors:
    return ""
  if r.verified or not settings.verifiedOnly:
    return "violation"
  if r.verificationError:
    # could be a live secret: on_error decides
    return "error"
  return ""

proc addFinding(findings: var seq[PolicyFinding], seen: var HashSet[string],
                settings: SecretsConfig, r: SecretResult, kind, location, where: string) =
  let key = r.detector & "\0" & location & "\0" & r.commit & "\0" & r.severity()
  if key in seen:
    return
  seen.incl(key)
  findings.add(newSubjectFinding(ruleName, kind, r.detector, settings.reason(r, where),
                                 location = location, severity = r.severity()))

proc check*(settings:  SecretsConfig,
            results:   seq[SecretResult],
            dir:       string,
            dockerignore: seq[string],
            relative = true): seq[PolicyFinding] =
  ## Findings for the results of scanning context directory `dir`. Locations
  ## are relative to `dir` unless `relative` is false.
  var seen = initHashSet[string]()
  for r in results:
    let kind = settings.findingKind(r)
    # filesystem mode paths are absolute
    if kind == "" or not r.file.isAbsolute():
      continue
    let inContext = r.file.contextPath("/", dir)
    if inContext.isNone():
      continue
    let rel = inContext.get()
    # docker never sends ignored files, so their secrets cannot reach the image
    if rel.isExcluded(dockerignore) or rel.isExcluded(settings.excludePaths):
      continue
    let path = if relative: rel else: r.file
    result.addFinding(seen, settings, r, kind, path & ":" & $r.line,
                      "in the build context")

proc checkMark*(settings: SecretsConfig, results: seq[SecretResult]): seq[PolicyFinding] =
  ## Findings for the results recorded in a pushed image's chalk mark.
  ## Git mode paths are relative to the repository, filesystem mode paths are
  ## absolute on the build host, so `exclude_paths` only applies to the former.
  var seen = initHashSet[string]()
  for r in results:
    let kind = settings.findingKind(r)
    if kind == "":
      continue
    if not r.file.isAbsolute() and r.file.isExcluded(settings.excludePaths):
      continue
    result.addFinding(seen, settings, r, kind, r.file & ":" & $r.line,
                      "recorded in the image's chalk mark")

proc toolCallback[T](name: string, dir: string): T =
  let value = runCallback(attrGet[CallbackObj]("tool.trufflehog." & name), @[pack(dir)])
  if value.isNone():
    raise newException(ValueError, "missing implementation of tool.trufflehog." & name)
  return unpack[T](value.get())

proc trufflehogCommand(dir: string, verify: bool): string =
  ## Reuses the trufflehog tool configuration (docker or local binary,
  ## installer, timeout, `trufflehog_config`) but always in filesystem mode.
  if not sectionExists("tool.trufflehog"):
    raise newException(ValueError, "the trufflehog tool is not configured")
  var exe = toolCallback[string]("get_tool_location", dir)
  if exe == "":
    if not toolCallback[bool]("attempt_install", dir):
      raise newException(ValueError, "trufflehog is not available and could not be installed")
    exe = toolCallback[string]("get_tool_location", dir)
  if exe == "":
    raise newException(ValueError, "trufflehog is not available")
  # .git holds history, not files docker uses; regexes per trufflehog -x
  let exclude = writeNewTempFile("[.]git(/|$)\n", suffix = ".txt")
  var args = @["filesystem", "--json", "--no-update",
               "-x", exclude.quoteShell()]
  if not verify:
    args.add("--no-verification")
  let config = attrGetOpt[string]("tool.trufflehog.trufflehog_config").get("")
  if config != "":
    args.add("--config=" & config.quoteShell())
  args.add(dir.quoteShell())
  return exe & " " & args.join(" ")

var scanned = initTable[string, seq[SecretResult]]()

proc scanDir(dir: string, verify: bool): seq[SecretResult] =
  ## cached as every policy enabling the rule scans the same directories
  let key = $verify & ":" & dir
  if key in scanned:
    return scanned[key]
  let cmd = trufflehogCommand(dir, verify)
  trace("policy: secrets: " & cmd)
  var output: ExecOutput
  unprivileged:
    output = runCmdGetEverything("/bin/sh", @["-c", cmd])
  let code = output.getExit()
  if code in timeoutExits:
    raise newException(ValueError, "trufflehog timed out after " &
                       attrGetOpt[string]("tool.trufflehog.trufflehog_timeout").get("") &
                       "s (tool.trufflehog.trufflehog_timeout)")
  # stdout holds the secrets, so neither output is logged
  if code != 0 and code != trufflehogFoundExit:
    raise newException(ValueError, "trufflehog exited with code " & $code)
  result = parseTrufflehogOutput(output.getStdout())
  scanned[key] = result

var loaded: SecretsConfig

proc loadSecrets(): bool =
  let settings = loadSecretsConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkSecrets(input: PolicyInput): seq[PolicyFinding] =
  var findings: seq[PolicyFinding]
  if input.command == "push":
    # the build context is gone; only what chalk recorded at build time is left
    if not loaded.checkPush:
      return
    for mark in input.pushMarks:
      try:
        findings.add(loaded.checkMark(mark.markSecretResults()))
      except CatchableError:
        findings.add(newSubjectFinding(ruleName, "error", "SECRET_SCANNER",
                                       "could not read secret scanner results: " &
                                       getCurrentExceptionMsg()))
    return findings.capFindings(ruleName, maxFindings, "secrets")
  if len(input.contextDirs) == 0:
    return @[newSubjectFinding(ruleName, "error", "build context",
                               "the build context is not a local directory and cannot be scanned for secrets")]
  for i, dir in input.contextDirs:
    # the Dockerfile's own ignore file only applies to the main context
    let dockerfile = if i == 0: input.dockerfilePath else: ""
    try:
      let results = scanDir(dir, loaded.verify)
      findings.add(loaded.check(results, dir, readDockerignore(dir, dockerfile),
                                relative = i == 0))
    except CatchableError:
      findings.add(newSubjectFinding(ruleName, "error", dir,
                                     "could not scan for secrets: " & getCurrentExceptionMsg()))
  return findings.capFindings(ruleName, maxFindings, "secrets")

proc secretsHint(): PolicyHint =
  # without a message the summary has no generic "how to fix" for secrets
  if loaded.message != "":
    result = PolicyHint(rule: ruleName, message: loaded.message)

proc loadSecretsRule*() =
  newPolicyInputRule(ruleName, loadSecrets, checkSecrets, hint = secretsHint)
