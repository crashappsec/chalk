##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/strutils
import ".."/[
  collect,
  reporting,
  run_management,
  types,
  utils/json,
]
import "./types" as podman_types

const redactedArgText* = "<<redact>>"
const commandWhitespace = {' ', '\t', '\n', '\r', '\v', '\f'}
const commandOperators = {';', '&', '|', '<', '>', '(', ')'}

type
  ShellWordStatus = enum
    swsParsed,
    swsMissing,
    swsMalformed,
    swsUnsupported
  ShellWord = object
    status: ShellWordStatus
    decoded: string
    rawEnd: int

proc decodeShellWord(text: string, rawStart: int): ShellWord =
  if rawStart >= len(text) or
      text[rawStart] in commandWhitespace + commandOperators:
    return ShellWord(status: swsMissing)

  result.status = swsParsed
  var index = rawStart
  var quote = '\0'
  while index < len(text):
    let current = text[index]
    if quote == '\0':
      if current in {'<', '>'} and index + 1 < len(text) and
          text[index + 1] == '(':
        return ShellWord(status: swsUnsupported)
      if current in commandWhitespace + commandOperators:
        break
      case current
      of '\'':
        quote = '\''
        inc index
      of '"':
        quote = '"'
        inc index
      of '\\':
        if index + 1 >= len(text):
          return ShellWord(status: swsMalformed)
        if text[index + 1] != '\n':
          result.decoded.add(text[index + 1])
        index += 2
      of '$', '`', '*', '?', '[', '{', '}', '~':
        return ShellWord(status: swsUnsupported)
      else:
        result.decoded.add(current)
        inc index
    elif quote == '\'':
      if current == '\'':
        quote = '\0'
      else:
        result.decoded.add(current)
      inc index
    else:
      case current
      of '"':
        quote = '\0'
        inc index
      of '\\':
        if index + 1 >= len(text):
          return ShellWord(status: swsMalformed)
        let escaped = text[index + 1]
        if escaped == '\n':
          index += 2
        elif escaped in {'$', '`', '"', '\\'}:
          result.decoded.add(escaped)
          index += 2
        else:
          result.decoded.add('\\')
          inc index
      of '$', '`':
        return ShellWord(status: swsUnsupported)
      else:
        result.decoded.add(current)
        inc index

  if quote != '\0':
    return ShellWord(status: swsMalformed)
  result.rawEnd = index

proc redactCommandArg(
    text: string,
    arg: podman_types.PodmanConfidentialArg,
): string =
  result = text
  var searchFrom = 0
  while searchFrom < len(result):
    let flagStart = result.find(arg.flag, searchFrom)
    if flagStart < 0:
      break
    let flagEnd = flagStart + len(arg.flag)
    if flagStart > 0 and
        result[flagStart - 1] notin commandWhitespace + commandOperators:
      return redactedArgText

    var valueStart = flagEnd
    if valueStart < len(result) and result[valueStart] == '=':
      inc valueStart
    elif valueStart < len(result) and result[valueStart] in commandWhitespace:
      while valueStart < len(result) and
          result[valueStart] in commandWhitespace:
        inc valueStart
    elif valueStart >= len(result):
      if flagStart == 0:
        return result
      return redactedArgText
    elif result[valueStart] in
        commandOperators + {'\'', '"', '\\', '$', '`'}:
      return redactedArgText
    else:
      searchFrom = flagEnd
      continue

    let word = decodeShellWord(result, valueStart)
    case word.status
    of swsMissing, swsMalformed, swsUnsupported:
      return redactedArgText
    of swsParsed:
      discard
    if word.decoded != arg.value:
      searchFrom = flagEnd
      continue
    return redactedArgText

proc redactCommandText(text: string,
                       confidential: openArray[podman_types.PodmanConfidentialArg]):
                       string =
  result = text
  for arg in confidential:
    if arg.flag == "" or arg.value == "":
      continue
    result = redactCommandArg(result, arg)

proc redactPodmanArgv*(argv: seq[string],
                       confidential: openArray[podman_types.PodmanConfidentialArg]):
                       seq[string] =
  result = newSeqOfCap[string](len(argv))
  for index, token in argv:
    var redacted = token
    var matchedNative = false
    for arg in confidential:
      if token == arg.flag & "=" & arg.value:
        redacted = arg.flag & "=" & redactedArgText
        matchedNative = true
        break
      if (token == arg.value and '=' in arg.value) or
          (index > 0 and argv[index - 1] == arg.flag and
           token == arg.value):
        redacted = redactedArgText
        matchedNative = true
        break
      if token == arg.flag & "=" & redactedArgText or
          (index > 0 and argv[index - 1] == arg.flag and
           token == redactedArgText) or
          token == arg.flag:
        matchedNative = true
        break
    if not matchedNative:
      let normalizedToken = token.replace("'", "").replace("\"", "").replace(
        "\\", "",
      )
      for arg in confidential:
        if arg.value == "":
          continue
        if arg.value in token:
          redacted = redactedArgText
          matchedNative = true
          break
        let normalizedValue = arg.value.replace("'", "").replace(
          "\"", "",
        ).replace("\\", "")
        if normalizedValue != "" and normalizedValue in normalizedToken:
          redacted = redactedArgText
          matchedNative = true
          break
    if not matchedNative:
      redacted = redactCommandText(token, confidential)
    result.add(redacted)

proc redactArgvBox(value: Box,
                   confidential: openArray[podman_types.PodmanConfidentialArg]):
                   Box =
  if value.kind != MkSeq:
    return value
  var argv: seq[string]
  for item in unpack[seq[Box]](value):
    if item.kind != MkStr:
      return value
    argv.add(unpack[string](item))
  return pack(redactPodmanArgv(argv, confidential))

proc redactNestedArgvs(value: Box,
                       confidential: openArray[podman_types.PodmanConfidentialArg]):
                       Box =
  if value.kind != MkSeq:
    return value
  var argvs: seq[Box]
  for argv in unpack[seq[Box]](value):
    argvs.add(redactArgvBox(argv, confidential))
  return pack(argvs)

proc redactProcessArgvs(value: Box,
                        confidential: openArray[podman_types.PodmanConfidentialArg]):
                        Box =
  if value.kind != MkTable:
    return value
  let processes = unpack[ChalkDict](value)
  for pid, processValue in processes:
    if processValue.kind != MkTable:
      continue
    let process = unpack[ChalkDict](processValue)
    if "argv" in process:
      process["argv"] = redactArgvBox(process["argv"], confidential)
      processes[pid] = pack(process)
  return pack(processes)

proc redactRetainedText(
    text: string,
    confidential: openArray[podman_types.PodmanConfidentialArg],
): string =
  result = text
  for arg in confidential:
    if arg.value == "":
      continue
    # repr() prefixes strings with an address, which changes when a string is
    # copied. Match the complete quoted representation without that address.
    # Matching fragments would also erase unrelated keys and image operands.
    let represented = repr(arg.value)
    let quotedAt = represented.find('"')
    let stableRepresentation =
      if quotedAt >= 0: represented[quotedAt .. ^1]
      else: ""
    if arg.value in text or escape(arg.value) in text or
        ($newJString(arg.value)) in text or
        (stableRepresentation != "" and stableRepresentation in text):
      return redactedArgText

proc redactRetainedBox(
    value: Box,
    confidential: openArray[podman_types.PodmanConfidentialArg],
): Box =
  if value.isNil:
    return value
  case value.kind
  of MkStr:
    return pack(redactRetainedText(unpack[string](value), confidential))
  of MkSeq:
    var redacted: seq[Box]
    for item in unpack[seq[Box]](value):
      redacted.add(redactRetainedBox(item, confidential))
    return pack(redacted)
  of MkTable:
    try:
      let source = unpack[ChalkDict](value)
      let redacted = ChalkDict()
      for key, item in source:
        redacted[key] = redactRetainedBox(item, confidential)
      return pack(redacted)
    except CatchableError:
      # Report state uses string-keyed dictionaries. If another table type is
      # retained, redact the whole value when its printable form carries a
      # confidential representation instead of risking partial traversal.
      let printable = $value
      if redactRetainedText(printable, confidential) != printable:
        return pack(redactedArgText)
      return value
  of MkInt, MkFloat, MkBool, MkObj:
    return value

proc redactPodmanReportFields*(dict: ChalkDict,
                               confidential: openArray[podman_types.PodmanConfidentialArg]) =
  if dict == nil or len(confidential) == 0:
    return
  for key in ["INJECTOR_ARGV", "_ARGV", "_OP_ARGV", "_PROCESS_ARGV"]:
    if key in dict:
      dict[key] = redactArgvBox(dict[key], confidential)
  if "_OP_ANCESTOR_ARGVS" in dict:
    dict["_OP_ANCESTOR_ARGVS"] = redactNestedArgvs(
      dict["_OP_ANCESTOR_ARGVS"], confidential,
    )
  if "_OP_ALL_PS_INFO" in dict:
    dict["_OP_ALL_PS_INFO"] = redactProcessArgvs(
      dict["_OP_ALL_PS_INFO"], confidential,
    )
  for key, value in dict:
    dict[key] = redactRetainedBox(value, confidential)

proc redactPodmanRetainedState*(
    confidential: openArray[podman_types.PodmanConfidentialArg],
) =
  ## Remove confidential command values from every report-retained state
  ## container. ChalkObj.extract and cachedMark deliberately remain unchanged:
  ## they describe the embedded artifact mark and never receive native argv.
  if len(confidential) == 0:
    return
  setArgs(redactPodmanArgv(getArgs(), confidential))
  redactPodmanReportFields(hostInfo, confidential)
  redactPodmanReportFields(failedKeys, confidential)
  for index in 0 ..< len(systemErrors):
    systemErrors[index] = redactRetainedText(systemErrors[index], confidential)
  for actionIndex in 0 ..< len(externalActions):
    externalActions[actionIndex] = redactPodmanArgv(
      externalActions[actionIndex], confidential,
    )
  let context = getCurrentCollectionCtx()
  context.report = redactRetainedBox(context.report, confidential)
  for chalk in getAllChalks() & getAllArtifacts():
    if chalk == nil:
      continue
    redactPodmanReportFields(chalk.collectedData, confidential)
    redactPodmanReportFields(chalk.failedKeys, confidential)
    for index in 0 ..< len(chalk.err):
      chalk.err[index] = redactRetainedText(chalk.err[index], confidential)

proc doPodmanReporting*(
    reportArgs: seq[string],
    confidential: openArray[podman_types.PodmanConfidentialArg],
    topic: string,
    quietOutput = false,
) =
  ## Collect the last host facts, redact all report state, and prevent the
  ## reporting layer from recollecting raw process data before serialization.
  setArgs(reportArgs)
  try:
    collectRunTimeHostInfo()
  finally:
    redactPodmanRetainedState(confidential)
  suspendHostCollection()
  try:
    if quietOutput:
      doReportingWithStdoutRedirected(topic)
    else:
      doReporting(topic)
  finally:
    # A failing sink may retain an error after serialization starts. Scrub it
    # before the caller can reuse or cache the collection state.
    redactPodmanRetainedState(confidential)
    restoreHostCollection()
