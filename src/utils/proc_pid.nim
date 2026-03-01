##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  dirs,
  options,
  paths,
  posix,
  sequtils,
]
import pkg/[
  nimutils,
]
import "."/[
  files,
  json,
  proc_base,
  strings,
  tables,
]

type
  ProcInfo         = ref object
    pid*:            Pid
    # /proc/*/stat
    stats_loaded:    bool
    name*:           Option[string]
    state*:          Option[string]
    ppid*:           Option[Pid]
    pgrp*:           Option[int]
    sid*:            Option[int]
    tty_nr*:         Option[int]
    tpgid*:          Option[int]
    user_time*:      Option[float]
    system_time*:    Option[float]
    child_utime*:    Option[float]
    child_stime*:    Option[float]
    priority*:       Option[int]
    nice*:           Option[int]
    num_threads*:    Option[int]
    runtime*:        Option[float]
    # /proc/*/status
    status_loaded:   bool
    umask*:          Option[int]
    uid*:            Option[seq[int]]
    gid*:            Option[seq[int]]
    fdsize*:         Option[int]
    groups*:         Option[seq[int]]
    seccomp*:        Option[string]
    # /proc/*/cmdline
    argv*:           Option[seq[string]]
    # /proc/*/comm
    command*:        Option[string]
    # /proc/*/cwd
    cwd*:            Option[string]
    # /proc/*/exe
    path*:           Option[string]
    # /proc/*/mountinfo
    mounts*:         Option[seq[TableRef[string, string]]]
    # /proc/*/fdinfo/*
    # /proc/*/fd/*
    fds*:            Option[TableRef[string, ProcStringTable]]

let
  PATH_MAX {.importc, header: "<stdio.h>".}: int
  clockSpeed = float(sysconf(SC_CLK_TCK))
  stateMap   = {
    "R" : "Running",
    "S" : "Sleeping",
    "D" : "Waiting",
    "Z" : "Zombie",
    "T" : "Stopped",
    "t" : "Tracing stop",
    "X" : "Dead",
    "x" : "Dead",
    "K" : "Wakekill",
    "W" : "Waking",
    "P" : "Parked",
    "I" : "Idle"
  }.toTable()
  tcpStatusMap = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECEIVED",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0a", "0A": "LISTEN",
    "0b", "0B": "CLOSING",
    "0c", "0C": "NEW_SYN_RECV",
    "": "UNKNOWN",
  }.toTable()
  udpStatusMap = {
    "": "UNCONN",
  }.toTable()
  seccompMap = {
    "0": "disabled",
    "1": "strict",
    "2": "filter",
    "": "unknown",
  }.toTable()

proc clockConvert(input: string): float =
  # For this one, if anything in /proc changes, the parsing
  # throws an exception we'll catch and report on.
  return float(parseBiggestUInt(input)) / clockSpeed

iterator filterDirForInts(dir: Path): Path =
  ## Return file names that are all-integers within the folder
  for kind, path in walkDir(dir):
    var bailed = false
    for ch in path.splitPath().tail.string:
      if ch notin '0'..'9':
        bailed = true
        break
    if not bailed:
      yield path

proc loadStats*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.stats_loaded:
    return
  self.stats_loaded = true
  let contents = tryToLoadFile("/proc/" & $self.pid & "/stat")
  if contents == "":
    return
  let
    lparen   = contents.find('(')
    rparen   = contents.rfind(')')
  if lparen == -1 or rparen == -1:
    return
  let
    name  = contents[lparen + 1 ..< rparen]
    rest  = contents[rparen + 1 .. ^1].strip()
    parts = rest.split(' ')
  if len(parts) < 20:
    return
  self.name        = some(name)
  self.state       = some(stateMap[parts[0]])
  self.ppid        = some(Pid(parseInt(parts[1])))
  self.pgrp        = some(parseInt(parts[2]))
  self.sid         = some(parseInt(parts[3]))
  self.tty_nr      = some(parseInt(parts[4]))
  self.tpgid       = some(parseInt(parts[5]))
  self.user_time   = some(clockConvert(parts[11]))
  self.system_time = some(clockConvert(parts[12]))
  self.child_utime = some(clockConvert(parts[13]))
  self.child_stime = some(clockConvert(parts[14]))
  self.priority    = some(parseInt(parts[15]))
  self.nice        = some(parseInt(parts[16]))
  self.num_threads = some(parseInt(parts[17]))
  self.runtime     = some(clockConvert(parts[19]))

proc loadStatus*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.status_loaded:
    return
  self.status_loaded = true
  let mapOpt = loadStringTable("/proc/" & $self.pid & "/status")
  if mapOpt.isNone():
    return
  let map = mapOpt.get()
  if "Umask" in map:
    self.umask   = some(parseInt(map["Umask"]))
  if "Uid" in map:
    self.uid     = some(parseInts(map["Uid"].split('\t')))
  if "Gid" in map:
    self.gid     = some(parseInts(map["Gid"].split('\t')))
  if "FDSize" in map:
    self.fdsize  = some(parseInt(map["FDSize"]))
  if "Groups" in map:
    self.groups  = some(parseInts(map["Groups"].split(' ')))
  if "Seccomp" in map:
    self.seccomp = some(seccompMap.getOrDefault(map["Seccomp"], seccompMap[""]))

proc loadArgv*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.argv.isSome():
    return
  let contents = tryToLoadFile("/proc/" & $self.pid & "/cmdline")
  if contents == "":
    return
  var allArgs = contents.split('\x00')
  # Remove the trailing null argument.
  if len(allArgs[^1]) == 0:
    allArgs = allArgs[0 ..< ^1]
  self.argv = some(allArgs)

proc loadCommand*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.command.isSome():
    return
  self.command = optLoadFile("/proc/" & $self.pid & "/comm")

proc loadCwd*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.cwd.isSome():
    return
  self.cwd = optExpandSymlink("/proc/" & $self.pid & "/cwd")

proc loadPath*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.path.isSome():
    return
  self.path = optExpandSymlink("/proc/" & $self.pid & "/exe")

proc loadMountInfo*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.mounts.isSome():
    return
  let mountinfo = tryToLoadFile("/proc/" & $self.pid & "/mountinfo")
  if mountinfo == "":
    return
  var mounts = newSeq[TableRef[string, string]]()
  template setKeyIfNotEmpty(kv: TableRef[string, string], k: string, v: string) =
    if v != "":
      kv[k] = v
  for line in mountinfo.splitLines():
    let parts = line.split(' ')
    if len(parts) < 10:
      continue
    let (major, minor) = parts[2].splitBy(":")
    var mount = newTable[string, string]()
    mount.setKeyIfNotEmpty("mount_id",    parts[0])
    mount.setKeyIfNotEmpty("parent_id",   parts[1])
    mount.setKeyIfNotEmpty("major",       major)
    mount.setKeyIfNotEmpty("minor",       minor)
    mount.setKeyIfNotEmpty("root",        parts[3])
    mount.setKeyIfNotEmpty("mount_point", parts[4])
    mount.setKeyIfNotEmpty("options",     parts[5])
    mount.setKeyIfNotEmpty("tags",        parts[6])
    mount.setKeyIfNotEmpty("fs_type",     parts[7])
    mount.setKeyIfNotEmpty("source",      parts[8])
    mount.setKeyIfNotEmpty("super",       parts[9])
    mounts.add(mount)
  self.mounts = some(mounts)

proc loadFdInfo*(self: ProcInfo): ProcInfo {.discardable.} =
  result = self
  if self.fds.isSome():
    return

  var fds = newTable[string, ProcStringTable]()
  self.fds = some(fds)
  let
    procFdInfoDir = "/proc/" & $self.pid & "/fdinfo/"
    procFdDir     = "/proc/" & $self.pid & "/fd/"

  for path in filterDirForInts(Path(procFdInfoDir)):
    let infoOpt = loadStringTable(path)
    if infoOpt.isSome():
      var info = infoOpt.get()
      let
        fd      = string(path.splitPath().tail)
        pathOpt = optExpandSymlink(procFdDir & fd)
      if pathOpt.isSome():
        info["path"] = string(pathOpt.get())
      fds[fd] = info

proc loadFull*(self: ProcInfo, all = false): ProcInfo {.discardable.} =
  result = self
  self.loadStatus()
  self.loadStats()
  self.loadArgv()
  self.loadCommand()
  self.loadCwd()
  self.loadPath()
  if all:
    self.loadMountInfo()
    self.loadFdInfo()

proc asJson*(self: ProcInfo): JsonNode =
  result = %*(self)
  for k in result.keys().toSeq():
    if k.endsWith("_loaded") or result[k].kind == JNull:
      result.delete(k)

let procs = newTable[Pid, ProcInfo]()
proc getOrNewProc*(pid: Pid): ProcInfo =
  return procs.mgetOrPut(pid, ProcInfo(
    pid: pid,
  ))

proc parent*(self: ProcInfo): Option[ProcInfo] =
  self.loadStatus()
  if self.ppid.isNone():
    return none(ProcInfo)
  return some(getOrNewProc(self.ppid.get()))

iterator parents*(self: ProcInfo): ProcInfo =
  var p = self.parent()
  while p.isSome():
    yield p.get()
    p = p.get().parent()

iterator iterAllProcs*(): ProcInfo =
  for path in filterDirForInts(Path("/proc/")):
    let pid = Pid(parseInt(string(path.splitPath().tail)))
    yield getOrNewProc(pid)
