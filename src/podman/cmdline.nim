##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  options,
  strutils,
]
import "./notice"
import "./report"
import "./chalk_platform"
import "./types"

type NoticeTarget = object
  operation:   PodmanOperation
  leadingFlag: Option[SafeFlagName]

const
  podmanGlobalBooleanFlags = [
    "-r",
    "--remote",
    "--syslog",
    "--transient-store",
  ]
  podmanGlobalValueFlags = [
    "--cgroup-manager",
    "--config",
    "--conmon",
    "--connection",
    "--db-backend",
    "--events-backend",
    "--hooks-dir",
    "--identity",
    "--imagestore",
    "--log-level",
    "--module",
    "--network-cmd-path",
    "--network-config-dir",
    "--out",
    "--root",
    "--runroot",
    "--runtime",
    "--runtime-flag",
    "--ssh",
    "--storage-driver",
    "--storage-opt",
    "--tls-ca",
    "--tls-cert",
    "--tls-key",
    "--tmpdir",
    "--url",
    "--volumepath",
  ]

proc commandHelp(args: seq[string], start: int): bool =
  for i in start ..< len(args):
    if args[i] == "--":
      return false
    if args[i] in ["-h", "--help"] or args[i].startsWith("--help="):
      return true
  return false

proc rememberLeadingFlag(target: var Option[SafeFlagName], raw: string) =
  if target.isNone():
    target = safeFlagName(raw)

proc noticeTarget(args: seq[string]): Option[NoticeTarget] =
  var
    i           = 0
    leadingFlag = none(SafeFlagName)
  while i < len(args) and args[i].startsWith("-") and args[i] != "-":
    let cur = args[i]
    if cur in ["-h", "--help", "-v", "--version"] or
        cur.startsWith("--help=") or cur.startsWith("--version="):
      return none(NoticeTarget)
    if cur == "--":
      return none(NoticeTarget)
    var matched = false
    for flag in podmanGlobalBooleanFlags:
      if cur == flag or cur.startsWith(flag & "="):
        leadingFlag.rememberLeadingFlag(cur)
        i += 1
        matched = true
        break
    if matched:
      continue
    for flag in podmanGlobalValueFlags:
      if cur == flag:
        if i + 1 >= len(args):
          return none(NoticeTarget)
        leadingFlag.rememberLeadingFlag(cur)
        i += 2
        matched = true
        break
      if cur.startsWith(flag & "="):
        leadingFlag.rememberLeadingFlag(cur)
        i += 1
        matched = true
        break
    if matched:
      continue
    if cur == "-c":
      if i + 1 >= len(args):
        return none(NoticeTarget)
      leadingFlag.rememberLeadingFlag(cur)
      i += 2
      continue
    if cur.startsWith("-c") and len(cur) > 2:
      leadingFlag.rememberLeadingFlag(cur)
      i += 1
      continue
    return none(NoticeTarget)

  if i >= len(args):
    return none(NoticeTarget)
  var
    operation: Option[PodmanOperation]
    argStart = i + 1
  case args[i]
  of "build": operation = some(poBuild)
  of "push":  operation = some(poPush)
  of "pull":  operation = some(poPull)
  of "image":
    if i + 1 >= len(args):
      return none(NoticeTarget)
    argStart = i + 2
    case args[i + 1]
    of "build": operation = some(poBuild)
    of "push":  operation = some(poPush)
    of "pull":  operation = some(poPull)
    else:        return none(NoticeTarget)
  of "buildx":
    if i + 1 >= len(args) or args[i + 1] != "build":
      return none(NoticeTarget)
    operation = some(poBuild)
    argStart = i + 2
  else:
    return none(NoticeTarget)

  if commandHelp(args, argStart):
    return none(NoticeTarget)
  return some(NoticeTarget(
    operation:   operation.get(),
    leadingFlag: leadingFlag,
  ))

proc quietPassThrough(args: seq[string]): PodmanRoute =
  return PodmanRoute(
    kind:         prPassThrough,
    skip:         none(PodmanSkip),
    originalArgs: args,
  )

proc passThrough(args: seq[string], reason: PodmanSkipReason): PodmanRoute =
  let targetOpt = noticeTarget(args)
  if targetOpt.isNone():
    return quietPassThrough(args)
  let target = targetOpt.get()
  return PodmanRoute(
    kind: prPassThrough,
    skip: some(PodmanSkip(
      operation: target.operation,
      reason:    reason,
    )),
    originalArgs: args,
  )

proc unmatchedPassThrough(args: seq[string]): PodmanRoute =
  let targetOpt = noticeTarget(args)
  if targetOpt.isNone():
    return quietPassThrough(args)
  let target = targetOpt.get()
  let reason =
    if target.leadingFlag.isSome():
      PodmanSkipReason(
        kind: psrUnsupportedFlag,
        flag: target.leadingFlag,
      )
    else:
      PodmanSkipReason(kind: psrUnsupportedCommandForm)
  return PodmanRoute(
    kind:         prPassThrough,
    skip:         some(PodmanSkip(operation: target.operation, reason: reason)),
    originalArgs: args,
  )

proc unsupportedFlagReason(raw: string): PodmanSkipReason =
  return PodmanSkipReason(
    kind: psrUnsupportedFlag,
    flag: safeFlagName(raw),
  )

proc invalidFlagReason(raw: string): PodmanSkipReason =
  return PodmanSkipReason(
    kind: psrInvalidFlag,
    flag: safeFlagName(raw),
  )

proc looksRemoteContext(value: string): bool =
  if value == "-" or value == "":
    return true
  if "://" in value:
    return true
  if value.startsWith("git@"):
    return true
  if value.endsWith(".git"):
    return true
  return false

type
  BuildFlagArity = enum
    bfaBare,
    bfaValue,
    bfaOptionalValue
  BuildFlagRole = enum
    bfrForward,
    bfrQuiet,
    bfrConfidential,
    bfrFile,
    bfrTag,
    bfrPlatform,
    bfrFormat,
    bfrIidFile,
    bfrBuildContext,
    bfrTarget,
    bfrPull
  BuildFlagSpec = object
    names: seq[string]
    arity: BuildFlagArity
    role:  BuildFlagRole
  FlagMatchKind = enum
    fmNone, fmBare, fmInline, fmSeparated, fmMissingValue, fmInvalidValue
  FlagMatch = object
    spec:         BuildFlagSpec
    kind:         FlagMatchKind
    value:        string
    valueIndex:   int
    equalsPrefix: string
    consumed:     int
    flagName:     string

const buildFlags = [
  BuildFlagSpec(names: @["-f", "--file"],    arity: bfaValue,         role: bfrFile),
  BuildFlagSpec(names: @["-t", "--tag"],     arity: bfaValue,         role: bfrTag),
  BuildFlagSpec(names: @["--platform"],      arity: bfaValue,         role: bfrPlatform),
  BuildFlagSpec(names: @["--format"],        arity: bfaValue,         role: bfrFormat),
  BuildFlagSpec(names: @["--iidfile"],       arity: bfaValue,         role: bfrIidFile),
  BuildFlagSpec(names: @["--build-context"], arity: bfaValue,         role: bfrBuildContext),
  BuildFlagSpec(names: @["--target"],        arity: bfaValue,         role: bfrTarget),
  BuildFlagSpec(names: @["--pull"],          arity: bfaOptionalValue, role: bfrPull),
  BuildFlagSpec(names: @["--build-arg"],     arity: bfaValue,         role: bfrConfidential),
  BuildFlagSpec(names: @["--secret"],        arity: bfaValue,         role: bfrConfidential),
  BuildFlagSpec(names: @["--ssh"],           arity: bfaValue,         role: bfrConfidential),
  BuildFlagSpec(names: @["--env"],           arity: bfaValue,         role: bfrConfidential),
  BuildFlagSpec(names: @["--label"],         arity: bfaValue,         role: bfrForward),
  BuildFlagSpec(names: @["--cache-from"],    arity: bfaValue,         role: bfrForward),
  BuildFlagSpec(names: @["--cache-to"],      arity: bfaValue,         role: bfrForward),
  BuildFlagSpec(names: @["--network"],       arity: bfaValue,         role: bfrForward),
  BuildFlagSpec(names: @["--annotation"],    arity: bfaValue,         role: bfrForward),
  BuildFlagSpec(names: @["--no-cache"],      arity: bfaBare,          role: bfrForward),
  BuildFlagSpec(names: @["-q", "--quiet"],   arity: bfaBare,          role: bfrQuiet),
  BuildFlagSpec(names: @["--layers"],        arity: bfaBare,          role: bfrForward),
  BuildFlagSpec(names: @["--rm"],            arity: bfaBare,          role: bfrForward),
  BuildFlagSpec(names: @["--force-rm"],      arity: bfaBare,          role: bfrForward),
  BuildFlagSpec(names: @["--squash"],        arity: bfaBare,          role: bfrForward),
  BuildFlagSpec(names: @["--squash-all"],    arity: bfaBare,          role: bfrForward),
]

proc canonicalFlagName(spec: BuildFlagSpec): string =
  for name in spec.names:
    if name.startsWith("--"):
      return name
  return spec.names[0]

proc isExplicitBool(value: string): bool =
  return value in ["true", "True", "TRUE", "false", "False", "FALSE"]

proc parsePullPolicy(value: string): Option[BasePullPolicy] =
  case value
  of "always": some(bppAlways)
  of "missing": some(bppMissing)
  of "never": some(bppNever)
  of "newer": some(bppNewer)
  else: none(BasePullPolicy)

proc parseNamedContext(raw: string): Option[string] =
  let eq = raw.find('=')
  if eq <= 0 or eq == len(raw) - 1:
    return none(string)
  return some(raw[0 ..< eq])

proc matchBuildFlag(args: seq[string], i: int): FlagMatch =
  let cur = args[i]
  for spec in buildFlags:
    for name in spec.names:
      let prefix = name & "="
      if cur == name:
        result.spec = spec
        result.flagName = canonicalFlagName(spec)
        case spec.arity
        of bfaBare, bfaOptionalValue:
          result.kind = fmBare
          result.valueIndex = -1
          result.consumed = 1
        of bfaValue:
          if i + 1 >= len(args) or args[i + 1] == "--":
            result.kind = fmMissingValue
            result.consumed = 1
          elif args[i + 1].startsWith("-"):
            result.kind = fmInvalidValue
            result.consumed = 1
          else:
            result.kind = fmSeparated
            result.value = args[i + 1]
            result.valueIndex = i + 1
            result.consumed = 2
        return
      if cur.startsWith(prefix):
        result.spec = spec
        result.flagName = canonicalFlagName(spec)
        result.kind = fmInline
        result.value = cur[len(prefix) .. ^1]
        result.valueIndex = i
        result.equalsPrefix = prefix
        result.consumed = 1
        case spec.arity
        of bfaBare:
          if not isExplicitBool(result.value):
            result.kind = fmInvalidValue
        of bfaOptionalValue:
          if parsePullPolicy(result.value).isNone():
            result.kind = fmInvalidValue
        of bfaValue:
          discard
        return
  result.kind = fmNone
  result.consumed = 0

# Flags that take no value, so skipping them cannot swallow the image operand.
# Deliberately short: a bare flag we do not recognise might or might not consume
# the next token, and guessing wrong would mean scanning the wrong image.
const transferBooleanFlags = [
  "-q", "--quiet",
  "-a", "--all-tags",
  "--compress",
  "--disable-content-trust",
  "--remove-signatures",
  "--tls-verify",
]

proc classifyTransfer(args: seq[string], kind: PodmanRouteKind,
                      maxPositionals: int): PodmanRoute =
  ## Find the image operand of a push or pull.
  ##
  ## `--flag=value` is self-contained and safe to skip. Any other unrecognised
  ## flag passes the command through rather than risk mis-identifying which
  ## operand is the image.
  var
    positionals: seq[string]
    i           = 1
    afterDash   = false
  while i < len(args):
    let cur = args[i]
    if not afterDash and cur == "--":
      afterDash = true
      i += 1
      continue
    if not afterDash and cur.startsWith("-") and cur != "-":
      if "=" in cur:
        i += 1
        continue
      if cur in transferBooleanFlags:
        i += 1
        continue
      return passThrough(args, unsupportedFlagReason(cur))
    positionals.add(cur)
    i += 1

  if len(positionals) < 1 or len(positionals) > maxPositionals:
    return passThrough(args, PodmanSkipReason(kind: psrOperandUnavailable))
  let image = positionals[0]
  if image == "" or image == "-" or "://" in image:
    return passThrough(args, PodmanSkipReason(kind: psrUnsupportedReference))
  return PodmanRoute(
    kind:         kind,
    originalArgs: args,
    image:        image,
  )

proc classifyPodmanArgs*(args: seq[string]): PodmanRoute =
  if len(args) == 0:
    return quietPassThrough(args)
  # `podman push IMAGE [DESTINATION]`, `podman pull IMAGE`
  if args[0] == "push":
    return classifyTransfer(args, prPush, 2)
  if args[0] == "pull":
    return classifyTransfer(args, prPull, 1)
  if args[0] != "build":
    return unmatchedPassThrough(args)

  var
    i              = 1
    fileArg        = ""
    platform       = ""
    imageFormat    = ""
    quietOutput    = false
    target         = ""
    iidFile        = ""
    fileValueIndex = -1
    filePrefix     = ""
    fileSeen       = false
    platformSeen   = false
    formatSeen     = false
    targetSeen     = false
    pullSeen       = false
    dashDashIndex  = -1
    tags: seq[string]
    contextNames: seq[string]
    confidentialArgs: seq[PodmanConfidentialArg]
    pullPolicy     = bppMissing
    reportArgs     = args
    positionals: seq[tuple[index: int, value: string]]

  proc redactValue(index: int, equalsPrefix, flag, value: string) =
    confidentialArgs.add(PodmanConfidentialArg(flag: flag, value: value))
    if equalsPrefix != "":
      reportArgs[index] = equalsPrefix & redactedArgText
    else:
      reportArgs[index] = redactedArgText

  while i < len(args):
    let cur = args[i]
    if dashDashIndex < 0 and cur == "--":
      dashDashIndex = i
      i += 1
      continue
    if dashDashIndex >= 0 or not cur.startsWith("-") or cur == "-":
      positionals.add((i, cur))
      i += 1
      continue
    let matched = matchBuildFlag(args, i)
    case matched.kind
    of fmNone:
      return passThrough(args, unsupportedFlagReason(cur))
    of fmMissingValue, fmInvalidValue:
      return passThrough(args, invalidFlagReason(matched.flagName))
    of fmBare, fmInline, fmSeparated:
      let value = matched.value
      case matched.spec.role
      of bfrForward:
        discard
      of bfrQuiet:
        quietOutput = matched.kind == fmBare or
                      value in ["true", "True", "TRUE"]
      of bfrConfidential:
        if value == "":
          return passThrough(args, invalidFlagReason(matched.flagName))
        redactValue(matched.valueIndex, matched.equalsPrefix,
                    matched.flagName, value)
      of bfrFile:
        if fileSeen:
          return passThrough(args, invalidFlagReason("--file"))
        fileSeen = true
        fileArg = value
        fileValueIndex = matched.valueIndex
        filePrefix = matched.equalsPrefix
      of bfrTag:
        if value == "":
          return passThrough(args, invalidFlagReason("--tag"))
        tags.add(value)
      of bfrPlatform:
        if platformSeen:
          return passThrough(args, invalidFlagReason("--platform"))
        platformSeen = true
        platform = value
      of bfrFormat:
        if formatSeen:
          return passThrough(args, invalidFlagReason("--format"))
        formatSeen = true
        imageFormat = value
      of bfrIidFile:
        if value == "":
          return passThrough(args, invalidFlagReason("--iidfile"))
        iidFile = value
      of bfrBuildContext:
        let name = parseNamedContext(value)
        if name.isNone():
          return passThrough(args, invalidFlagReason("--build-context"))
        let contextName = name.get()
        if contextName in contextNames:
          return passThrough(args, invalidFlagReason("--build-context"))
        contextNames.add(contextName)
        redactValue(matched.valueIndex, matched.equalsPrefix,
                    matched.flagName, value)
      of bfrTarget:
        if targetSeen or value == "":
          return passThrough(args, invalidFlagReason("--target"))
        targetSeen = true
        target = value
      of bfrPull:
        if pullSeen:
          return passThrough(args, invalidFlagReason("--pull"))
        pullSeen = true
        if matched.kind == fmBare:
          pullPolicy = bppAlways
        else:
          pullPolicy = parsePullPolicy(value).get()
      i += matched.consumed

  if fileSeen and (fileArg == "" or fileArg == "-"):
    return passThrough(args, invalidFlagReason("--file"))
  if platformSeen and parseCommandPlatform(platform).isNone():
    return passThrough(args, invalidFlagReason("--platform"))
  if formatSeen and imageFormat != "oci":
    return passThrough(args, invalidFlagReason("--format"))
  if len(positionals) != 1:
    return passThrough(args, PodmanSkipReason(kind: psrOperandUnavailable))
  let context = positionals[0]
  if looksRemoteContext(context.value):
    return passThrough(args, PodmanSkipReason(kind: psrNonLocalContext))

  return PodmanRoute(
    kind:         prInstrument,
    originalArgs: args,
    spec: PodmanBuildSpec(
      originalArgs:       args,
      reportArgs:         reportArgs,
      confidentialArgs:   confidentialArgs,
      contextArg:         context.value,
      containerfileArg:   fileArg,
      tags:               tags,
      requestedPlatform:  parseCommandPlatform(platform),
      imageFormat:        imageFormat,
      quietOutput:        quietOutput,
      target:             target,
      customerIidFile:    iidFile,
      contextNames:       contextNames,
      pullPolicy:         pullPolicy,
      fileValueIndex:     fileValueIndex,
      fileEqualsPrefix:   filePrefix,
      contextIndex:       context.index,
      dashDashIndex:      dashDashIndex,
    ),
  )
