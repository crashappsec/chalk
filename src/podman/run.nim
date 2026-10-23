##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  posix,
]
import ".."/[
  norecurse,
  types,
  utils/exe,
]
import "./types" as podman_types

when defined(posix):
  {.compile: "run.c".}

  type ChalkPodmanCChild {.
      importc: "chalk_podman_child_t", header: "podman/run.h", bycopy.} = object
      kind:         cint
      exit_code:    cint
      sig:          cint
      forwarded:    cint
      stdout_bytes: cstring
      stderr_bytes: cstring

  proc chalk_podman_exec_replacing_self(exe: cstring, argv: cstringArray): cint
    {.importc, cdecl, header: "podman/run.h".}
  proc chalk_podman_run_attached(exe: cstring, argv: cstringArray, capture: cint,
                                 outp: ptr ChalkPodmanCChild): cint
    {.importc, cdecl, header: "podman/run.h".}
  proc chalk_podman_child_free(child: ptr ChalkPodmanCChild)
    {.importc, cdecl, header: "podman/run.h".}

var podmanExeLocation = ""

proc resolvePodmanExe*(): string =
  ## Locate the genuine podman binary to exec, skipping any candidate that is
  ## itself a chalk binary. This mirrors getDockerExeLocation(): the configured
  ## podman_exe path is prepended ahead of PATH, and ignoreChalkExes sub-scans
  ## each candidate so a chalk copy installed as `podman` (which is exactly what
  ## setup.sh's PATH interposition creates) is never re-exec'd into a loop.
  once:
    let
      podmanConfigPath = attrGetOpt[string]("podman_exe")
      podmanExeOpt     = findExePath("podman",
                                     configPath      = podmanConfigPath,
                                     ignoreChalkExes = true)
    podmanExeLocation = podmanExeOpt.get("")
    # Backstop for a chalk build that is not itself chalked, which the
    # ignoreChalkExes sub-scan cannot recognize. Returning "" makes callers
    # exit 127 rather than recursing into ourselves.
    if podmanExeLocation != "":
      try:
        if sameFile(podmanExeLocation, getMyAppPath()):
          podmanExeLocation = ""
      except:
        discard
    if podmanExeLocation == "":
      warn("podman: no command found in PATH. `chalk podman` not available.")
  return podmanExeLocation

proc toChildResult(raw: ChalkPodmanCChild): podman_types.ChildResult =
  result.forwardedSignal = int(raw.forwarded)
  case int(raw.kind)
  of 1:
    result.kind   = podman_types.ceSignaled
    result.signal = int(raw.sig)
  of 2:
    result.kind     = podman_types.ceSpawnFailed
    result.exitCode = 127
  else:
    result.kind     = podman_types.ceExited
    result.exitCode = int(raw.exit_code)

proc execReplacingSelf*(exe: string; args: seq[string]) {.noreturn.} =
  restoreChalkRecursionMarker()
  if exe == "":
    quit(127)
  let argv = allocCStringArray(@[exe] & args)
  discard chalk_podman_exec_replacing_self(cstring(exe), argv)
  quit(127)

proc runAttached*(exe: string; args: seq[string]): podman_types.ChildResult =
  restoreChalkRecursionMarker()
  var raw: ChalkPodmanCChild
  let argv = allocCStringArray(@[exe] & args)
  try:
    discard chalk_podman_run_attached(cstring(exe), argv, 0, addr raw)
    result = toChildResult(raw)
  finally:
    chalk_podman_child_free(addr raw)
    deallocCStringArray(argv)

proc runCaptured*(exe: string; args: seq[string]):
                 tuple[child: podman_types.ChildResult, stdout: string, stderr: string] =
  restoreChalkRecursionMarker()
  var raw: ChalkPodmanCChild
  let argv = allocCStringArray(@[exe] & args)
  try:
    discard chalk_podman_run_attached(cstring(exe), argv, 1, addr raw)
    result.child = toChildResult(raw)
    if raw.stdout_bytes != nil:
      result.stdout = $raw.stdout_bytes
    if raw.stderr_bytes != nil:
      result.stderr = $raw.stderr_bytes
  finally:
    chalk_podman_child_free(addr raw)
    deallocCStringArray(argv)
