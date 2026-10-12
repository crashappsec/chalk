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
##
## Requires trufflehog >= 3.90.9 for `--fail-on-scan-errors`.

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
  dockerignore,
  helpers,
]
from ".."/tools import maxContextDirs

const
  ruleName    = "secrets"
  maxFindings = 100
  # trufflehog exits with 183 when `--fail` is set and it found results
  # https://github.com/trufflesecurity/trufflehog#exit-codes
  trufflehogFoundExit = 183
  # exit codes of `timeout`, see `with_timeout` in base_callbacks.c4m
  timeoutExits = [124, 137]
  # https://github.com/trufflesecurity/trufflehog/pull/4476
  scanErrorsFlag    = "--fail-on-scan-errors"
  scanErrorsVersion = "3.90.9"
  # trufflehog matches every path against each `-x` regex, so past this many
  # the rest of the ignored paths is scanned and only filtered afterwards
  maxExcludes* = 1000
  # entries `trufflehogExcludes` walks: preparing the scan runs before
  # `trufflehog_timeout` applies, so it must stay bounded on huge contexts
  maxExcludeVisits* = 100_000
  # what is read of trufflehog's stdout (results) and stderr (diagnostics),
  # so a scan cannot exhaust memory with output
  maxOutputBytes*      = 32 * 1024 * 1024
  maxDiagnosticsBytes* = 4 * 1024 * 1024

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

  TrufflehogScan* = object
    ## The results trufflehog printed, also when the scan did not complete,
    ## so secrets it found are violations whatever `on_error` says.
    results*: seq[SecretResult]
    error*:   string # why the scan is incomplete, empty when it completed

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

proc hasScanDiagnostics(diagnostics: string): bool =
  # --json selects JSON diagnostics on stderr as well. Filesystem traversal
  # sometimes logs failures without propagating them to the exit code.
  # Never copy diagnostic messages, paths or error values into findings.
  const messages = ["unable to get file info", "error scanning filesystem",
                    "error scanning file", "error scanning directory",
                    "error scanning symlink", "encountered errors during scan"]
  for line in diagnostics.splitLines():
    let text = line.strip()
    if not text.startsWith("{"):
      # Wrappers may emit ordinary non-JSON messages, but known filesystem
      # failures still mean the scan is incomplete.
      for message in messages:
        if message in text.toLowerAscii():
          return true
      continue
    var node: JsonNode
    try:
      node = parseJson(text)
    except CatchableError:
      return true # uninterpretable diagnostics cannot establish a clean scan
    if node.kind != JObject:
      return true
    let message = node{"msg"}.getStr(node{"message"}.getStr()).toLowerAscii()
    if message in messages:
      return true
    # A verification failure is represented on each result and is handled
    # by verified_only; it is not a filesystem scan failure.
  false

proc checkedTrufflehogOutput*(code: int, output, diagnostics: string,
                              timeout = "",
                              maxOutput = maxOutputBytes,
                              maxDiagnostics = maxDiagnosticsBytes): TrufflehogScan =
  ## Results and completeness of a filesystem scan, from the output of
  ## `boundedCommand`. Messages are fixed text; either stream may contain a
  ## secret. Raises `ValueError` when stdout is not trufflehog's JSON.
  var output = output
  if len(output) >= maxOutput:
    # cut off mid-line by `boundedCommand`, and trufflehog died writing the
    # rest (SIGPIPE): only complete lines are results
    output = output[0 ..< maxOutput]
    output.setLen(max(0, output.rfind('\n')))
    result.error = "trufflehog printed more than " & $maxOutput &
                   " bytes of results; the rest were not checked"
  elif len(diagnostics) >= maxDiagnostics:
    result.error = "trufflehog printed more than " & $maxDiagnostics &
                   " bytes of diagnostics; the scan cannot be confirmed complete"
  elif code in timeoutExits:
    result.error = "trufflehog timed out" &
                   (if timeout == "": "" else: " after " & timeout & "s") &
                   " (tool.trufflehog.trufflehog_timeout)"
  elif code != 0 and code != trufflehogFoundExit:
    # kingpin's error for an unknown flag
    if ("unknown long flag '" & scanErrorsFlag & "'") in diagnostics & output:
      result.error = "trufflehog >= " & scanErrorsVersion & " is required (" &
                     scanErrorsFlag & " is not supported)"
    else:
      result.error = "trufflehog exited with code " & $code
  elif diagnostics.hasScanDiagnostics():
    result.error = "trufflehog reported scan errors; filesystem analysis is incomplete"
  try:
    result.results = parseTrufflehogOutput(output)
  except ValueError:
    # a failed run may print anything; its own error explains it better
    if result.error == "":
      raise

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
            ignore:    DockerIgnore,
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
    if ignore.isIgnored(rel) or rel.isExcluded(settings.excludePaths):
      continue
    let path = if relative: rel else: r.file
    result.addFinding(seen, settings, r, kind, path & ":" & $r.line,
                      "in the build context")

proc checkDockerfile*(settings: SecretsConfig, results: seq[SecretResult],
                      location: string): seq[PolicyFinding] =
  ## Findings for the results of scanning the Dockerfile alone, reported at
  ## `location`. BuildKit always sends the Dockerfile, whatever
  ## `.dockerignore` says, and `ENV`/`ARG` defaults end up in the image.
  var seen = initHashSet[string]()
  for r in results:
    let kind = settings.findingKind(r)
    if kind == "":
      continue
    result.addFinding(seen, settings, r, kind, location & ":" & $r.line,
                      "in the Dockerfile")

proc scannedWith*(dockerfile, dir: string, ignore: DockerIgnore): bool =
  ## whether scanning context `dir` covers the Dockerfile
  if dockerfile == "":
    return false
  let rel = dockerfile.contextPath("/", dir)
  rel.isSome() and not ignore.isIgnored(rel.get())

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

proc reQuote(s: string): string =
  ## as Go's regexp.QuoteMeta
  for c in s:
    if c in {'\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$'}:
      result.add('\\')
    result.add(c)

proc trufflehogExcludes*(dir: string, ignore: DockerIgnore,
                         excludePaths: seq[string],
                         maxVisits = maxExcludeVisits): seq[string] =
  ## trufflehog `-x` regexes, matched against the absolute paths it walks,
  ## for what docker does not send or `exclude_paths` drops, so trufflehog
  ## neither reads (or unpacks) those files nor fails the scan on them.
  ## Directories are skipped whole when no negation can re-include anything
  ## below them. `check` still filters results, so this only saves work,
  ## and it stops after `maxExcludes` regexes or `maxVisits` entries.
  ##
  ## A `.git` directory docker sends is history rather than build files, and
  ## scanning its objects is costly: only its `config` is scanned, which may
  ## hold credentialed remote URLs or `actions/checkout`'s extraheader.
  let root = dir.strip(leading = false, chars = {'/'})
  proc regex(rel: string, isDir: bool): string =
    "^" & reQuote(root & "/" & rel) & (if isDir: "(/|$)" else: "$")
  proc excluded(rel: string): bool =
    ignore.isIgnored(rel) or rel.isExcluded(excludePaths)
  var pending = @[""]
  var visits = 0
  while len(pending) > 0:
    let rel = pending.pop()
    for kind, name in walkDir(if rel == "": dir else: dir / rel, relative = true):
      inc(visits)
      if len(result) >= maxExcludes or visits > maxVisits:
        trace("policy: secrets: stopped listing excluded paths of " & dir)
        return
      let path = if rel == "": name else: rel & "/" & name
      if kind == pcDir:
        if path.isExcluded(excludePaths) or ignore.prunes(path):
          result.add(regex(path, true))
        elif name == ".git":
          for entryKind, entry in walkDir(dir / path, relative = true):
            inc(visits)
            let entryPath = path & "/" & entry
            if entry != "config" or excluded(entryPath):
              result.add(regex(entryPath, entryKind == pcDir))
        else:
          pending.add(path)
      elif excluded(path):
        result.add(regex(path, false))

proc trufflehogArguments*(path: string, verify: bool, exclude = "", config = ""): seq[string] =
  ## Arguments are shell-quoted because the configured executable may be a
  ## timeout or container wrapper. Keep scan-error signaling independent of
  ## secret verification and retain the scanner's native ignore-tag behavior.
  result = @["filesystem", "--json", "--no-update", scanErrorsFlag]
  if exclude != "":
    result.add(["-x", exclude.quoteShell()])
  if not verify:
    result.add("--no-verification")
  if config != "":
    result.add("--config=" & config.quoteShell())
  result.add(path.quoteShell())

proc boundedCommand*(cmd: string, maxStdout = maxOutputBytes,
                     maxStderr = maxDiagnosticsBytes): string =
  ## A `/bin/sh` script running `cmd` with its stdout and stderr cut after
  ## the given number of bytes (`cmd` then gets SIGPIPE), exiting with
  ## `cmd`'s exit code. `cmd` runs in a subshell so an `exit` in it cannot
  ## skip reporting the code, which fd 3 carries out of the pipelines; 4 and
  ## 5 are the original stdout and stderr.
  "exec 4>&1 5>&2; code=$({ { { ( " & cmd & "\n) 3>&- 4>&- 5>&-; echo $? >&3; } | " &
    "head -c " & $maxStdout & " >&4; } 2>&1 | head -c " & $maxStderr & " >&5; } 3>&1); " &
    "exit ${code:-1}"

proc trufflehogCommand(path: string, verify: bool, excludes: seq[string]): string =
  ## Reuses the trufflehog tool configuration (docker or local binary,
  ## installer, timeout, `trufflehog_config`) but always in filesystem mode.
  if not sectionExists("tool.trufflehog"):
    raise newException(ValueError, "the trufflehog tool is not configured")
  var exe = toolCallback[string]("get_tool_location", path)
  if exe == "":
    if not toolCallback[bool]("attempt_install", path):
      raise newException(ValueError, "trufflehog is not available and could not be installed")
    exe = toolCallback[string]("get_tool_location", path)
  if exe == "":
    raise newException(ValueError, "trufflehog is not available")
  # in the temp directory, which the docker variant of the tool mounts
  let exclude = if len(excludes) == 0: ""
                else: writeNewTempFile(excludes.join("\n") & "\n", suffix = ".txt")
  let config = attrGetOpt[string]("tool.trufflehog.trufflehog_config").get("")
  let args = trufflehogArguments(path, verify, exclude, config)
  return exe & " " & args.join(" ")

var scanned = initTable[string, TrufflehogScan]()

proc scanPath(path: string, verify: bool, excludes: seq[string] = @[]): TrufflehogScan =
  ## cached as every policy enabling the rule scans the same directories,
  ## including a failed scan, so a timeout is not waited for again;
  ## `exclude_paths` differs between policies, so it is part of the key
  let key = $verify & "\0" & path & "\0" & excludes.join("\n")
  if key in scanned:
    return scanned[key]
  let cmd = trufflehogCommand(path, verify, excludes)
  trace("policy: secrets: " & cmd)
  var output: ExecOutput
  unprivileged:
    output = runCmdGetEverything("/bin/sh", @["-c", boundedCommand(cmd)])
  # stdout holds the secrets, so neither output is logged
  result = checkedTrufflehogOutput(output.getExit(), output.getStdout(), output.stderr,
                                   attrGetOpt[string]("tool.trufflehog.trufflehog_timeout").get(""))
  scanned[key] = result

var loaded: SecretsConfig

proc loadSecrets(): bool =
  let settings = loadSecretsConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc unscannable*(input: PolicyInput): seq[PolicyFinding] =
  ## build inputs the rule cannot scan, besides the engine's `contextErrors`
  if len(input.contextDirs) == 0:
    if len(input.contextErrors) == 0:
      result.add(newSubjectFinding(ruleName, "error", "build context",
                                   "the build context is not a local directory and cannot be scanned for secrets"))
  elif input.mainContextDir != "" and input.dockerfilePath == "" and
       input.stdinDockerfile == "":
    result.add(newSubjectFinding(ruleName, "error", "Dockerfile",
                                 "the Dockerfile from stdin cannot be scanned for secrets"))

proc scannedContexts*(input: PolicyInput, findings: var seq[PolicyFinding]): seq[string] =
  ## the context directories to scan, reporting those past `maxContextDirs`
  result = input.contextDirs
  if len(result) > maxContextDirs:
    findings.add(newSubjectFinding(ruleName, "error", "",
                                   "only the first " & $maxContextDirs &
                                   " build contexts were scanned for secrets"))
    result.setLen(maxContextDirs)

proc checkSecrets(input: PolicyInput): seq[PolicyFinding] =
  var findings: seq[PolicyFinding]
  if input.command == "push":
    # the build context is gone; only what chalk recorded at build time is left
    if not loaded.checkPush:
      return
    for mark in input.pushMarks:
      if mark == nil:
        continue
      try:
        findings.add(loaded.checkMark(mark.markSecretResults()))
      except CatchableError:
        findings.add(newSubjectFinding(ruleName, "error", "SECRET_SCANNER",
                                       "could not read secret scanner results: " &
                                       getCurrentExceptionMsg()))
    return findings.capFindings(ruleName, maxFindings, "secrets")
  findings.add(input.unscannable())
  let dockerfile = input.dockerfilePath
  var dockerfileScanned = false
  for dir in input.scannedContexts(findings):
    let main = dir == input.mainContextDir
    try:
      let ignore = loadDockerignore(dir, input.mainContextDockerfile(dir))
      let scan = scanPath(dir, loaded.verify,
                          trufflehogExcludes(dir, ignore, loaded.excludePaths))
      findings.add(loaded.check(scan.results, dir, ignore, relative = main))
      if scan.error != "":
        findings.add(newSubjectFinding(ruleName, "error", dir,
                                       "could not scan for secrets: " & scan.error))
      elif dockerfile.scannedWith(dir, ignore):
        dockerfileScanned = true
    except CatchableError:
      findings.add(newSubjectFinding(ruleName, "error", dir,
                                     "could not scan for secrets: " & getCurrentExceptionMsg()))
  # with a remote main context the Dockerfile is usually in it, which the
  # engine already reports as not checked
  if dockerfile != "" and not dockerfileScanned and
     (input.mainContextDir != "" or dockerfile.fileExists()):
    let rel = if input.mainContextDir == "": none(string)
              else: dockerfile.contextPath("/", input.mainContextDir)
    if rel.isNone() or not rel.get().isExcluded(loaded.excludePaths):
      try:
        let scan = scanPath(dockerfile, loaded.verify)
        findings.add(loaded.checkDockerfile(scan.results, rel.get(dockerfile)))
        if scan.error != "":
          findings.add(newSubjectFinding(ruleName, "error", dockerfile,
                                         "could not scan the Dockerfile for secrets: " & scan.error))
      except CatchableError:
        findings.add(newSubjectFinding(ruleName, "error", dockerfile,
                                       "could not scan the Dockerfile for secrets: " &
                                       getCurrentExceptionMsg()))
  if input.stdinDockerfile != "":
    const location = "Dockerfile (stdin)"
    try:
      let path = writeNewTempFile(input.stdinDockerfile, suffix = ".Dockerfile")
      let scan = scanPath(path, loaded.verify)
      findings.add(loaded.checkDockerfile(scan.results, location))
      if scan.error != "":
        findings.add(newSubjectFinding(ruleName, "error", location,
                                       "could not scan the Dockerfile for secrets: " & scan.error))
    except CatchableError:
      findings.add(newSubjectFinding(ruleName, "error", location,
                                     "could not scan the Dockerfile for secrets: " &
                                     getCurrentExceptionMsg()))
  return findings.capFindings(ruleName, maxFindings, "secrets")

proc secretsHint(): PolicyHint =
  # without a message the summary has no generic "how to fix" for secrets
  if loaded.message != "":
    result = PolicyHint(rule: ruleName, message: loaded.message)

proc loadSecretsRule*() =
  newPolicyInputRule(ruleName, loadSecrets, checkSecrets, requiresContext = true,
                     hint = secretsHint)
