##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  exitprocs,
  posix,
]
import pkg/[
  nimutils,
]
import ".."/[
  types,
]
import "."/[
  files,
  tables,
]

let
  LC_ALL {.importc, header: "<locale.h>".}: cint
  sigNameMap = {
    1:  "SIGHUP",
    2:  "SIGINT",
    3:  "SIGQUIT",
    4:  "SIGILL",
    6:  "SIGABRT",
    7:  "SIGBUS",
    9:  "SIGKILL",
    11: "SIGSEGV",
    15: "SIGTERM",
  }.toTable()

var savedTermState: Termcap

proc setlocale(category: cint, locale: cstring): cstring {. importc, cdecl,
                                nodecl, header: "<locale.h>", discardable .}

proc restoreTerminal() {.noconv.} =
  tcsetattr(cint(1), TcsaConst.TCSAFLUSH, savedTermState)

proc regularTerminationSignal(signal: cint) {.noconv.} =
  let pid = getpid()
  try:
    error("pid: " & $(pid) & " - Aborting due to signal: " &
          sigNameMap[signal] & "(" & $(signal) & ")")
    if attrGet[bool]("chalk_debug"):
      publish("debug", "Stack trace: \n" & getStackTrace())

  except:
    echo("pid: " & $(pid) & " - Aborting due to signal: " &
         sigNameMap[signal]  & "(" & $(signal) & ")")
    dumpExOnDebug()
  var sigset:  Sigset

  discard sigemptyset(sigset)

  for signal in [SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGBUS, SIGKILL,
                 SIGSEGV, SIGTERM]:
    discard sigaddset(sigset, signal)
  discard sigprocmask(SIG_SETMASK, sigset, sigset)

  tmpfile_on_exit()

  exitnow(signal + 128)

proc setupTerminal*() =
  setlocale(LC_ALL, cstring(""))
  tcgetattr(cint(1), savedTermState)
  addExitProc(restoreTerminal)

proc setupSignalHandlers*() =
  var
    handler = Sigaction(
      sa_handler: regularTerminationSignal,
      sa_flags:   0,
    )
    ignore = Sigaction(
      sa_handler: SIG_IGN,
    )

  for signal in [SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGBUS, SIGKILL,
                 SIGSEGV, SIGTERM]:
    discard sigaction(signal, handler, nil)
  for signal in [SIGTTOU, SIGTTIN]:
    discard sigaction(signal, ignore, nil)
