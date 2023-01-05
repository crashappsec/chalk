# Do not import this.  Import config instead, it includes this.
type LogLevel* = enum
  logLevelNone, logLevelErr, logLevelWarn, logLevelVerbose,
  logLevelTrace

import resources
import terminal
export styledWriteLine, styledWrite
import options
export options

# Error handling helpers.
# TODO... normalize filename variables
# TODO... format file name first on everything.

proc getLogLevel*(): string
proc getColor*(): bool
proc getConfigErrors*(): Option[seq[string]]

let
  exename = getAppFileName().splitPath().tail
  infoPrefix* = fmtInfoPrefix.fmt()
  warnPrefix* = fmtWarnPrefix.fmt()
  errPrefix* = fmtErrPrefix.fmt()
  tracePrefix* = fmtTracePrefix.fmt()
  
when not defined(release):
  let
    debugPrefix = fmtDebugPrefix.fmt()

proc logLevel(): LogLevel =
  case getLogLevel()
  of "none": return logLevelNone
  of "error": return logLevelErr
  of "warn": return logLevelWarn
  of "info": return logLevelVerbose
  of "trace": return logLevelTrace
  else: return logLevelWarn # default until any config loads

template trace*(items: varargs[string]) =
  if logLevel() >= logLevelTrace:
    if getColor():
      stderr.styledWrite(traceColor, styleBright, tracePrefix, ansiResetCode)
    else:
      stderr.write(tracePrefix)

    for item in items:
      stderr.write(item, errSep)
    stderr.writeLine("")

template inform*(items: varargs[string]) =
  if logLevel() >= logLevelVerbose:
    if getColor():
      stderr.styledWrite(infoColor, styleBright, infoPrefix, ansiResetCode)
    else:
      stderr.write(tracePrefix)

    for item in items:
      stderr.write(item, errSep)
    stderr.writeLine("")

# When the dry-run flag is set, some items need to output
# even if the log level is not Inform or higher. Pass in the
# force flag to indicate dry-run is set.
template forceInform*(items: varargs[string]) =
  if (logLevel() >= logLevelVerbose) or getDryRun():
    if getColor():
      stderr.styledWrite(infoColor, styleBright, infoPrefix, ansiResetCode)
    else:
      stderr.write(tracePrefix)

    for item in items:
      stderr.write(item, errSep)
    stderr.writeLine("")

template warn*(str: string, nested: bool = false) =
  if logLevel() >= logLevelWarn:
    if getColor():
      stderr.styledWrite(fgYellow, styleBright, warnPrefix, ansiResetCode)
    else:
      stderr.write(warnPrefix)
    if nested: stderr.write(nestedPrefix)
    stderr.writeLine(str)

template debug*(items: varargs[string]) =
  when not defined(release):
    const info = instantiationInfo()
    let fullPrefix = fmtDebug % [info.filename, $info.line, debugPrefix]

    if getColor():
      stderr.styledWrite(debugColor, styleBright, fullPrefix, ansiResetCode)
    else:
      stderr.write(fullPrefix)

    for item in items:
      stderr.write(item, errSep)
    stderr.writeLine("")


template fatal*(str: string, nested: bool = false) =
  if logLevel() != logLevelNone:
    if getColor():
      stderr.styledWrite(fgRed, styleBright, errPrefix, ansiResetCode)
    else:
      stderr.write(errPrefix)
    if nested: stderr.write(nestedPrefix)
    stderr.writeLine(str)

    when not defined(release):
      if logLevel() != logLevelNone:
        stderr.write(getStackTrace())

  quit(1)

template error*(str: string, die=true) =
  if logLevel() != logLevelNone:
    if getColor():
      stderr.styledWrite(fgRed, styleBright, errPrefix, ansiResetCode)
    else:
      stderr.write(errPrefix)

    stderr.writeLine(str)

    when not defined(release):
      if logLevel() >= logLevelTrace:
        stderr.write(getStackTrace())


  let opterr = getConfigErrors()
  if opterr.isSome():
    for item in opterr.get():
      stderr.writeLine(item)
    quit()
