##
## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).
##
## Best-effort lifecycle signals. Deliberately independent of collection,
## report templates, sink state, report caching and HTTP delivery.

import std/[net, nativesockets, os, posix, times, monotimes]
import pkg/nimutils/sha
import "."/[
  config,
  types,
  plugins/system,
  utils/dns,
]

when hostOS == "macosx":
  proc proc_pidpath(pid: Pid, pathbuf: pointer, len: uint32): cint
    {.cdecl, header: "<libproc.h>", importc.}

type Beacon = object
  domain, server, version, execution, workspace: string

proc beaconConfig(): Option[Beacon] =
  if not attrGetOpt[bool]("redbox_beacon.enabled").get(false):
    return none(Beacon)
  var b = Beacon(
    domain: attrGet[string]("redbox_beacon.domain"),
    server: attrGet[string]("redbox_beacon.dns_server"),
    version: getChalkExeVersion().replace(".", "-"),
    execution: getExecutionId(),
    workspace: "na",
  )
  if b.domain == "":
    return none(Beacon)
  let workspace = attrGetOpt[string]("keyspec._X_WORKSPACE_ID.value").get("")
  if workspace != "":
    b.workspace = workspace.sha256().hex()[0 ..< 16].toLowerAscii()
  if b.server == "":
    b.server = systemDnsServer()
  if b.server == "":
    return none(Beacon)
  # Validate now; the delivery path must never resolve a resolver hostname.
  discard parseIpAddress(parseServerPort(b.server)[0])
  discard toAsciiDomain(b.domain)
  return some(b)

proc emit(b: Beacon, event: string, sequence: int, exitCode = "na") =
  let query = @[event, event & "1", b.version,
                $int64(getTime().toUnixFloat() * 1000), b.execution, $sequence,
                exitCode, b.workspace, "chalk", b.domain].join(".")
  sendDnsDatagram(query, b.server)

proc sendBuildBeacon*(exitCode: int) =
  # Invoked at the existing build exit boundaries, before report collection.
  try:
    if getBaseCommandName() != "build":
      return
    let b = beaconConfig()
    if b.isSome():
      b.get().emit("bs", 0, $exitCode)
  except:
    trace("redbox: build beacon skipped")

proc targetToken(pid: Pid): string =
  if kill(pid, 0) != 0:
    return ""
  when hostOS == "linux":
    # Stop for zombies even when a blocked collector has not reaped them.
    # Comparing start time also prevents following a reused PID.
    try:
      let stat = readFile("/proc/" & $pid & "/stat")
      let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace()
      if fields.len <= 19 or fields[0] in ["Z", "X"]:
        return ""
      return fields[19]
    except CatchableError:
      return ""
  elif hostOS == "macosx":
    var path: array[4096, char]
    if proc_pidpath(pid, addr path[0], uint32(path.len)) <= 0:
      return ""
  return "alive"

proc closeInheritedDescriptors() =
  # Do not keep command output pipes, report-cache locks or watcher FDs alive.
  let dir = when hostOS == "linux": "/proc/self/fd" else: "/dev/fd"
  var descriptors: seq[cint]
  for _, path in walkDir(dir):
    try:
      descriptors.add(cint(parseInt(path.extractFilename())))
    except ValueError:
      discard
  for fd in descriptors:
    discard posix.close(fd)

proc startExecBeacon*(target: Pid) =
  try:
    let config = beaconConfig()
    if config.isNone():
      return
    let
      b = config.get()
      token = targetToken(target)
      heartbeat = attrGet[bool]("exec.heartbeat.run")
      rateMs = max(1, int(attrGet[Con4mDuration]("exec.heartbeat.rate")) div 1000)
    try:
      b.emit("es", 0)
    except:
      discard
    if not heartbeat or token == "":
      return
    # A separate process keeps cadence independent of collection and blocking
    # report sinks. Reap the intermediate child to avoid a new zombie in Chalk.
    let child = fork()
    if child < 0:
      return
    if child > 0:
      var status: cint
      while waitpid(child, status, 0) < 0 and errno == EINTR:
        discard
      return
    let worker = fork()
    if worker != 0:
      exitnow(0)
    try:
      discard setsid()
      closeInheritedDescriptors()
      var
        count = 0
        deadline = getMonoTime() + initDuration(milliseconds = rateMs)
      while heartbeat and token != "" and targetToken(target) == token:
        # Poll liveness at least once per second without changing the cadence.
        let remaining = int((deadline - getMonoTime()).inMilliseconds())
        if remaining > 0:
          sleep(min(remaining, 1000))
          continue
        if targetToken(target) != token:
          break
        inc count
        try:
          b.emit("hs", count)
        except:
          discard
        deadline = getMonoTime() + initDuration(milliseconds = rateMs)
    except:
      discard
    finally:
      exitnow(0)
  except:
    trace("redbox: exec beacon skipped")
