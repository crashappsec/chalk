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
import "../docker"/dockerfile

type
  PodmanOperation* = enum
    poBuild, poPush, poPull

  SafeFlagName* = distinct string

  PodmanSkipReasonKind* = enum
    psrUnsupportedCommandForm,
    psrUnsupportedFlag,
    psrInvalidFlag,
    psrOperandUnavailable,
    psrUnsupportedReference,
    psrNonLocalContext,
    psrNativeExecutableUnavailable,
    psrContextUnavailable,
    psrContainerfileUnavailable,
    psrContainerfileIgnoreUnsupported,
    psrContainerfileOutsideContext,
    psrContainerfileUnreadable,
    psrBinaryIncompatible,
    psrContainerfileIssue,
    psrHostInfoInvalid,
    psrUnsupportedHostOs,
    psrUnsupportedHostArch,
    psrRemoteHost,
    psrNoStartup,
    psrImageBindingUnavailable,
    psrIncompatibleImagePlatform,
    psrUnresolvedImagePlatform,
    psrImageScanUnavailable

  PodmanSkipReason* = object
    case kind*: PodmanSkipReasonKind
    of psrUnsupportedFlag, psrInvalidFlag:
      flag*: Option[SafeFlagName]
    of psrContainerfileIssue:
      issue*: ContainerfileIssue
    else:
      discard

  PodmanSkip* = object
    operation*: PodmanOperation
    reason*:    PodmanSkipReason

  PodmanAttemptStep* = enum
    pasHostInspection,
    pasCollectionInitialization,
    pasWorkspacePreparation,
    pasMarkCreation,
    pasInstrumentedBuildStart,
    pasInstrumentedBuildRun

  NativeRetryKind* = enum
    nrSucceeded, nrExited

  NativeRetryResult* = object
    case kind*: NativeRetryKind
    of nrExited:
      status*: int
    of nrSucceeded:
      discard

const maxSafeFlagNameLength = 64

proc isAsciiAlphaNumeric(c: char): bool =
  return c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}

proc safeFlagName*(raw: string): Option[SafeFlagName] =
  var name = ""
  if raw.startsWith("--"):
    let equals = raw.find('=')
    name = if equals < 0: raw else: raw[0 ..< equals]
    if len(name) <= 2:
      return none(SafeFlagName)
  elif len(raw) >= 2 and raw[0] == '-' and raw[1] != '-':
    name = raw[0 .. 1]
  else:
    return none(SafeFlagName)

  let firstNameIndex = if name.startsWith("--"): 2 else: 1
  if len(name) > maxSafeFlagNameLength or
      not isAsciiAlphaNumeric(name[firstNameIndex]):
    return none(SafeFlagName)
  for i in firstNameIndex ..< len(name):
    if not isAsciiAlphaNumeric(name[i]) and name[i] notin {'-', '_'}:
      return none(SafeFlagName)
  return some(SafeFlagName(name))

proc operationName(operation: PodmanOperation): string =
  case operation
  of poBuild: "build"
  of poPush:  "push"
  of poPull:  "pull"

proc flagName(flag: Option[SafeFlagName]): string =
  if flag.isSome():
    return string(flag.get())
  return ""

proc instructionName(instruction: ContainerInstruction): string =
  case instruction
  of ciAdd:        "ADD"
  of ciArg:        "ARG"
  of ciCmd:        "CMD"
  of ciCopy:       "COPY"
  of ciEntrypoint: "ENTRYPOINT"
  of ciEnv:        "ENV"
  of ciExpose:     "EXPOSE"
  of ciFrom:       "FROM"
  of ciHealthcheck: "HEALTHCHECK"
  of ciLabel:      "LABEL"
  of ciMaintainer: "MAINTAINER"
  of ciOnbuild:    "ONBUILD"
  of ciRun:        "RUN"
  of ciShell:      "SHELL"
  of ciStopsignal: "STOPSIGNAL"
  of ciUser:       "USER"
  of ciVolume:     "VOLUME"
  of ciWorkdir:    "WORKDIR"

proc formatContainerfileIssue(issue: ContainerfileIssue): string =
  if issue.kind == cfikMissingFrom:
    return "Containerfile has no FROM instruction"

  result = "Containerfile"
  if issue.instruction.isSome():
    result.add(" " & instructionName(issue.instruction.get()))
  if issue.line.isSome():
    result.add(" on line " & $issue.line.get())
  case issue.kind
  of cfikSyntax:
    result.add(" could not be parsed")
  of cfikVariableDependent:
    result.add(" is variable-dependent")
  of cfikUnsupportedForm:
    result.add(" has a form Chalk cannot instrument")
  of cfikMissingFrom:
    discard
  of cfikTargetUnavailable:
    result.add(" has no single stage named by --target")

proc formatReason(skip: PodmanSkip): string =
  case skip.reason.kind
  of psrUnsupportedCommandForm:
    return "unsupported command form"
  of psrUnsupportedFlag:
    let flag = flagName(skip.reason.flag)
    if flag != "":
      return "unsupported flag " & flag
    return "unsupported flag"
  of psrInvalidFlag:
    let flag = flagName(skip.reason.flag)
    case flag
    of "--file":
      return "--file must name one Containerfile"
    of "--tag":
      return "--tag must have a value"
    of "--platform":
      return "unsupported --platform option"
    of "--format":
      return "unsupported --format option"
    of "--iidfile":
      return "unsupported --iidfile option"
    of "--build-context":
      return "unsupported --build-context option"
    of "--target":
      return "unsupported --target option"
    of "--pull":
      return "unsupported --pull option"
    else:
      return "invalid flag"
  of psrOperandUnavailable:
    if skip.operation == poBuild:
      return "build context operand is missing or ambiguous"
    return "image operand is missing or ambiguous"
  of psrUnsupportedReference:
    return "unsupported image reference"
  of psrNonLocalContext:
    return "build context is not local"
  of psrNativeExecutableUnavailable:
    return "native Podman executable is unavailable"
  of psrContextUnavailable:
    return "build context is unavailable"
  of psrContainerfileUnavailable:
    return "Containerfile is unavailable"
  of psrContainerfileIgnoreUnsupported:
    return "Containerfile-specific ignore file is unsupported"
  of psrContainerfileOutsideContext:
    return "Containerfile is outside the build context"
  of psrContainerfileUnreadable:
    return "Containerfile cannot be read"
  of psrBinaryIncompatible:
    return "Chalk executable is incompatible with linux/amd64 images"
  of psrContainerfileIssue:
    return formatContainerfileIssue(skip.reason.issue)
  of psrHostInfoInvalid:
    return "Podman host information is invalid"
  of psrUnsupportedHostOs:
    return "host operating system is unsupported"
  of psrUnsupportedHostArch:
    return "host architecture is unsupported"
  of psrRemoteHost:
    return "remote Podman hosts are unsupported"
  of psrNoStartup:
    return "image startup configuration is unavailable"
  of psrImageBindingUnavailable:
    return "an immutable selected-base identity is unavailable"
  of psrIncompatibleImagePlatform:
    return "image platform is incompatible with the Chalk executable"
  of psrUnresolvedImagePlatform:
    return "image platform could not be determined"
  of psrImageScanUnavailable:
    return "local image scan is unavailable"

proc formatPodmanSkip*(skip: PodmanSkip): string =
  return "chalk: skipped Podman " & operationName(skip.operation) &
         " processing: " & formatReason(skip) & "."

proc writeOperationalNotice*(message: string) =
  try:
    stderr.writeLine(message)
    stderr.flushFile()
  except IOError, OSError:
    discard

proc emitPodmanSkip*(skip: PodmanSkip) =
  writeOperationalNotice(formatPodmanSkip(skip))

proc formatPodmanRetryStart*(step: PodmanAttemptStep,
                             status: Option[int] = none(int)): string =
  var failure: string
  case step
  of pasHostInspection:
    failure = "Podman host inspection"
  of pasCollectionInitialization:
    failure = "Chalk collection initialization"
  of pasWorkspacePreparation:
    failure = "Chalk workspace preparation"
  of pasMarkCreation:
    failure = "Chalk mark creation"
  of pasInstrumentedBuildStart:
    failure = "the instrumented Podman build startup"
  of pasInstrumentedBuildRun:
    failure = "the instrumented Podman build"

  if status.isSome():
    failure.add(" exited with status " & $status.get())
  else:
    failure.add(" did not succeed")
  return "chalk: " & failure &
         "; retrying the original build without instrumentation."

proc formatPodmanRetryResult*(retry: NativeRetryResult): string =
  case retry.kind
  of nrSucceeded:
    return "chalk: Build succeeded; Chalk did not instrument this build."
  of nrExited:
    return "chalk: the native Podman retry exited with status " &
           $retry.status & "; Chalk did not instrument this build."

proc emitPodmanRetryStart*(step: PodmanAttemptStep,
                           status: Option[int] = none(int)) =
  writeOperationalNotice(formatPodmanRetryStart(step, status))

proc emitPodmanRetryResult*(retry: NativeRetryResult) =
  writeOperationalNotice(formatPodmanRetryResult(retry))
