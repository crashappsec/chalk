## Pull metadata from the proc file system on Linux.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

when hostOs != "linux":
  {.warning[UnusedImport]: off.}

import posix, re, base64, ../config, ../plugin_api

type
  ProcDict   = OrderedTableRef[string, string]
  ProcFdSet  = TableRef[string, ProcDict]
  ProcTable  = seq[seq[string]]

  ProcFSCache* = ref object of RootRef
    tcpSockInfoCache: Option[ProcTable]
    udpSockInfoCache: Option[ProcTable]
    psInfoCache:      Option[ProcFdSet]

template readOneFile(fname: string): Option[string] =
  let stream = newFileStream(fname, fmRead)
  if stream == nil:
    none(string)
  else:
    let contents = stream.readAll().strip()
    if len(contents) == 0:
       none(string)
    else:
      stream.close()
      some(contents)

const PATH_MAX = 4096 # PROC_PIDPATHINFO_MAXSIZE on mac
let
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

{.warning[PtrToCStringConv]: off.}

template procReadLink(s: string): Option[string] =
  var n: array[PATH_MAX, char]

  if readlink(cstring(s), addr n, PATH_MAX) <= 0:
    none(string)
  else:
    some($(cast[cstring](addr(n[0]))))

template filterDirForInts(dir: string): seq[string] =
  # Return file names that are all-integers.
  var res: seq[string]

  for kind, path in walkDir(dir):
    var bailed = false

    for ch in path.splitPath().tail:
      if ch notin "0123456789":
        bailed = true
        break
    if not bailed:
      res.add(path)
  res

proc tableFileSplit(path: string): ProcTable =
  let contentsOpt = readOneFile(path)

  if contentsOpt.isNone(): return

  let lines = contentsOpt.get().split("\n")[1 .. ^1]

  for line in lines:
    result.add(re.split(line, re"[\s]+"))

proc kvFileToProcDict(path: string): Option[ProcDict] =
  ## Read proc files that are in key/value pair format, one per line.
  let contentsOpt = readOneFile(path)

  if contentsOpt.isNone():
    return none(ProcDict)

  let lines = contentsOpt.get().split("\n")
  var res   = ProcDict()

  for line in lines:
    let ix = line.find(":")
    if ix == -1: continue
    res[line[0 ..< ix].strip()] = line[ix + 1 .. ^1].strip()

  return some(res)

proc getFdInfo(n: string): ProcFdSet =
  new result

  let
    procFdInfoDir = "/proc/" & n & "/fdinfo/"
    pids          = filterDirForInts(procFdInfoDir)

  for item in pids:
    # item will be the full path to the file.
    let
      fullFdPath = procFdInfoDir & item
    try:
      let
        retOpt     = kvFileToProcDict(fullFdPath)
      if retOpt.isSome():
        var procDict      = retOpt.get()
        let fd            = fullFdPath.splitPath().tail
        procDict["path"]  = fullFdPath
        let inodeOpt      = procReadLink(fullFdPath)

        if inodeOpt.isSome():
          procDict["ino"] = inodeOpt.get()

        result[fd]        = procDict
    except:
      warn("Unexpected failure in getFdInfo for " & fullFdPath)
      dumpExOnDebug()

proc getPidArgv(pid: string): string =
  let contentOpt = readOneFile("/proc/" & pid & "/cmdline")
  if contentOpt.isNone():
    return

  let contents = contentOpt.get()
  if len(contents) == 0:
    return

  var allArgs = contents.split('\x00')
  # Remove the trailing null argument.
  if len(allArgs[^1]) == 0:
    allArgs = allArgs[0 ..< ^1]

  return $(`%*`(allargs))

proc getPidCommandName(pid: string): string =
  return readOneFile("/proc/" & pid & "/comm").get("").strip()

proc getPidCwd(pid: string): string =
  return procReadLink("/proc/" & pid & "/cwd").get("")

proc getPidExePath(pid: string): string =
  return procReadLink("/proc/" & pid & "/exe").get("")

proc getPidExe(pid: string): string =
  # This currently isn't being used.
  return encode(readOneFile("/proc/" & pid & "/exe").get(""))

proc clockConvert(input: string): string =
  # For this one, if anything in /proc changes, the parsing
  # throws an exception we'll catch and report on.
  return $(float(parseBiggestUint(input)) / clockSpeed)

proc getPidStatInfo(pid: string, res: var ProcDict) =
  let statFieldOpt = readOneFile("/proc/" & pid & "/stat")

  if statFieldOpt.isNone():
    return

  let
    contents = statFieldOpt.get()
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

  res["name"]        = name
  res["state"]       = stateMap[parts[0]]
  res["ppid"]        = parts[1]
  res["pgrp"]        = parts[2]
  res["sid"]         = parts[3]
  res["tty_nr"]      = parts[4]
  res["tpgid"]       = parts[5]
  res["user_time"]   = clockConvert(parts[11])
  res["system_time"] = clockConvert(parts[12])
  res["child_utime"] = clockConvert(parts[13])
  res["child_stime"] = clockConvert(parts[14])
  res["priority"]    = parts[15]
  res["nice"]        = parts[16]
  res["num_threads"] = parts[17]
  res["runtime"]     = clockConvert(parts[19])

template putIf(outdict: ProcDict, k, n: string, indict: ProcDict) =
  if k in indict: outdict[n] = indict[k]

template xformUid(x: string): string =
  "[ " & x.replace("\t", ", ") & " ]"

template xformGroup(x: string): string =
  "[ " & x.replace(" ", ", ") & " ]"

template xformSeccomp(x: string): string =
  case x
  of "0": "disabled"
  of "1": "strict"
  of "2": "filter"
  else:   "unknown"

template putIf(outdict: ProcDict, k, n: string, indict: ProcDict, op: untyped) =
  if k in indict: outdict[n] = op(indict[k])

proc getPidStatusInfo(n: string, res: var ProcDict) =
  let map = kvFileToProcDict("/proc/" & n & "/status").get(nil)

  if map == nil:
    return

  res.putIf("Umask",   "umask",    map)
  res.putIf("Uid",     "uid",      map, xformUid)
  res.putIf("Gid",     "gid",      map, xformUid)
  res.putIf("FDSize",  "fdsize",   map)
  res.putIf("Groups",  "groups",   map, xformGroup)
  res.putIf("Seccomp", "seccomp",  map, xformSeccomp)

template setIfNotEmptyString(lhs: untyped, rhs: string) =
  let s = rhs
  if s != "":
    lhs = s

proc getFullProcessInfo(pid: string): ProcDict =
  # Returns most things that can be in key/val pair format.
  # This does not include process file descriptors, which
  # have to be requested seprately.
  #
  # It also does not include exes.  For the moment, we're
  # not supporting that, even tho the code is above.

  new result

  pid.getPidStatInfo(result)
  pid.getPidStatusInfo(result)

  setIfNotEmptyString(result["argv"], pid.getPidArgv())
  setIfNotEmptyString(result["command"], pid.getPidCommandName())
  setIfNotEmptyString(result["cwd"], pid.getPidCwd())
  setIfNotEmptyString(result["path"], pid.getPidExePath())

proc getMountInfo(pid: string): seq[ProcDict] =
  let mountinfo = readOneFile("/proc/" & pid & "/mountinfo").get("")

  if mountinfo == "": return

  for line in mountinfo.split("\n"):
    let res = ProcDict()

    let parts = line.split(' ')
    if len(parts) < 10:
      continue
    let majorMinor     = parts[2].split(":")

    setIfNotEmptyString(res["mount_id"]   , parts[0])
    setIfNotEmptyString(res["parent_id"]  , parts[1])
    if len(majorMinor) == 2:
      setIfNotEmptyString(res["major"]    , majorMinor[0])
      setIfNotEmptyString(res["minor"]    , majorMinor[1])
    setIfNotEmptyString(res["root"]       , parts[3])
    setIfNotEmptyString(res["mount_point"],  parts[4])
    setIfNotEmptyString(res["options"]    ,  parts[5])
    setIfNotEmptyString(res["tags"]       ,  parts[6])
    setIfNotEmptyString(res["fs_type"]    ,  parts[7])
    setIfNotEmptyString(res["source"]     ,  parts[8])
    setIfNotEmptyString(res["super"]      ,  parts[9])

    result.add(res)

proc getLoadInfo(): ProcDict =
  new result

  let info = readOneFile("/proc/loadavg").get("").strip().split(' ')

  if len(info) != 5: return

  result["load"]    = "( " & [info[0], info[1], info[2]].join(", ") & " )"
  result["lastpid"] = info[4]

  let cardnality = info[3].split("/")

  if len(cardnality) == 2:
    result["runnable_procs"] = cardnality[0]
    result["total_procs"]    = cardnality[1]

template getArpTable(): ProcTable =
  tableFileSplit("/proc/net/arp")

proc getIPv4Interfaces(): ProcTable =
  let contentsOpt = readOneFile("/proc/net/dev")

  if contentsOpt.isNone(): return

  var lines = contentsOpt.get().split("\n")

  if len(lines) < 3: return

  for line in lines[2 .. ^1]:
    let
      mostly = re.split(line, re"\s\s+")
      i      = mostly[0].find(':')

    if i == -1: continue

    result.add(@[mostly[0][0 ..< i], mostly[0][i+1 .. ^1].strip()] &
                 mostly[1..^1])

template getRawIPv6Interfaces(): ProcTable =
  tableFileSplit("/proc/net/if_inet6")

template getRawIPv4Routes(): ProcTable =
  tableFileSplit("/proc/net/route")

template getRawIPv6Routes(): ProcTable =
  tableFileSplit("/proc/net/ipv6_route")

template getRawTCPSockInfo(): Option[string] =
  readOneFile("/proc/net/tcp")

template getRawUDPSockInfo(): Option[string] =
  readOneFile("/proc/net/udp")

template procIPv6(s: string): string =
  if len(s) < 32:
    return

  s[0  ..< 4]  & ":" &
    s[4  ..< 8]  & ":" &
    s[8  ..< 12] & ":" &
    s[12 ..< 16] & ":" &
    s[16 ..< 20] & ":" &
    s[20 ..< 24] & ":" &
    s[24 ..< 28] & ":" &
    s[28 ..< 32]

proc getIPv6Interfaces(): ProcTable =
  let raw = getRawIPv6Interfaces()

  for row in raw:
    if len(row) < 1: return
    result.add(@[procIPv6(row[0])] & row[1 .. ^1])

proc getIPv6Routes(): ProcTable =
  let raw = getRawIPv6Routes()

  for row in raw:
    if len(row) < 10:
      continue
    # Reorder to make it more consistent wrt. IPV4 output.
    result.add(@[procIPv6(row[0]), row[1], procIPv6(row[2]), row[3],
                 procIPv6(row[4]), row[9], row[8], row[6], row[7],
                 row[5]])

template procIpV4(s: string): string =
  # This currently assumes little endian.
  if len(s) < 8:
    ""
  else:
    let
      hexByte1 = s[0 ..< 2]
      hexByte2 = s[2 ..< 4]
      hexByte3 = s[4 ..< 6]
      hexByte4 = s[6 ..< 8]

    try:
      # If we decide to support big endian platforms, reverse
      # the order of results here.
      $(fromHex[uint8](hexByte4)) & "." &
        $(fromHex[uint8](hexByte3)) & "." &
        $(fromHex[uint8](hexByte2)) & "." &
        $(fromHex[uint8](hexByte1))
    except:
      ""

template procPort(s: string): string =
  try:
    $(fromHex[uint16](s))
  except:
    ""

proc getIPV4Routes(): ProcTable =
  let raw = getRawIpV4Routes()

  for row in raw:
    if len(row) < 11:
      continue

    let
      dst = procIpV4(row[1])
      gw  = procIpV4(row[2])
      nm  = procIpV4(row[7])

    result.add(@[dst, gw, nm, row[0], row[3], row[4], row[5], row[6],row[8],
                 row[9], row[10]])

proc sockStatusMap(s: string): string =
  case s
  of "01":
    return "ESTABLISHED"
  of "02":
    return "SYN_SENT"
  of "03":
    return "SYN_RECEIVED"
  of "04":
    return "FIN_WAIT1"
  of "05":
    return "FIN_WAIT2"
  of "06":
    return "TIME_WAIT"
  of "07":
    return "CLOSE"
  of "08":
    return "CLOSE_WAIT"
  of "09":
    return "LAST_ACK"
  of "0a", "0A":
    return "LISTEN"
  of "0b", "0B":
    return "CLOSING"
  of "0c", "0C":
    return "NEW_SYN_RECV"
  else:
    return "UNKNOWN"

proc udpStatusMap(s: string): string = "UNCONN"

proc getSockInfo(raw: string, mapStatus: (string) -> string): ProcTable =
  let lines = raw.strip().split("\n")

  if len(lines) < 2:
    return

  for line in lines[1 .. ^1]:
    let parts = line.split(":")

    if len(parts) < 6: continue

    let
      toSplit1   = parts[2].split(' ')
      toSplit2   = parts[3].split(' ')
      junkdrawer = parts[5].split(' ')

      localAddr  = parts[1].strip()

    if len(toSplit1) < 2 or len(toSplit2) < 2: continue

    let
      localPort  = toSplit1[0]
      remoteAddr = toSplit1[1]
      remotePort = toSplit2[0]
      status     = toSplit2[1]

    var
      i     = 0
      count = 0
      uid:    string
      inode:  string

    while true:
      if junkdrawer[i] != "":
        count += 1
        if count == 3:
          uid = junkdrawer[i]
        elif count == 5:
          inode = junkdrawer[i]
          break
      i += 1

    result.add(@[ procIpV4(localAddr), procPort(localPort),
                  procIpV4(remoteAddr), procPort(remotePort),
                  mapStatus(status), uid, inode ])

template getTCPSockInfo(): ProcTable =
    getSockInfo(getRawTCPSockInfo().get(""), sockStatusMap)

template getUDPSockInfo(): ProcTable =
    getSockInfo(getRawUDPSockInfo().get(""), udpStatusMap)

# Can be used for UDP or TCP
# but currently isn't being used yet.
proc getProcSockInfo(allSockInfo: ProcTable, myFdInfo: ProcFdSet): ProcTable =
  var allInodes: seq[string]

  for k, v in myFdInfo:
    if "ino" in v:
      let oneInode = v["ino"]
      if oneInode notin allInodes:
        allInodes.add(oneInode)

  for item in allSockInfo:
    if item[6] in allInodes:
      result.add(item)

proc getPsAllInfo(): ProcFdSet =
  new result

  for item in filterDirForInts("/proc/"):
    let
      pid = item.splitPath().tail
      one = getFullProcessInfo(pid)

    result[pid] = one

proc procfsGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
       ChalkDict {.cdecl.} =
  result    = ChalkDict()
  let cache = ProcFsCache(self.internalState)

  if isSubscribedKey("_OP_TCP_SOCKET_INFO"):
    let info = getTCPSockInfo()
    cache.tcpSockInfoCache = some(info)
    setIfNotEmpty(result, "_OP_TCP_SOCKET_INFO", info)

  if isSubscribedKey("_OP_UDP_SOCKET_INFO"):
    let info = getUDPSockInfo()
    cache.udpSockInfoCache = some(info)
    setIfNotEmpty(result, "_OP_UDP_SOCKET_INFO", info)

  if isSubscribedKey("_OP_IPV4_ROUTES"):
    setIfNotEmpty(result, "_OP_IPV4_ROUTES", getIPv4Routes())

  if isSubscribedKey("_OP_IPV6_ROUTES"):
    setIfNotEmpty(result, "_OP_IPV6_ROUTES", getIPv6Routes())

  if isSubscribedKey("_OP_IPV4_INTERFACES"):
    setIfNotEmpty(result, "_OP_IPV4_INTERFACES", getIPv4Interfaces())

  if isSubscribedKey("_OP_IPV6_INTERFACES"):
    setIfNotEmpty(result, "_OP_IPV6_INTERFACES", getIPv6Interfaces())

  if isSubscribedKey("_OP_ARP_TABLE"):
    setIfNotEmpty(result, "_OP_ARP_TABLE", getArpTable())

  if isSubscribedKey("_OP_CPU_INFO"):
    let info = getLoadInfo()
    if info != nil and len(info) != 0:
      result["_OP_CPU_INFO"] = pack(info)

  if isSubscribedKey("_OP_ALL_PS_INFO"):
    let info = getPsAllInfo()
    cache.psInfoCache = some(info)
    if info != nil and len(info) != 0:
      result["_OP_ALL_PS_INFO"] = pack(info)

template loadDictKeyIfSubscribed(chalkKey: string, call: untyped) =
  if isSubscribedKey(chalkKey):
    let dict = call

    if dict != nil and len(dict) != 0:
      result[chalkKey] = pack(dict)

template loadArrKeyIfSubscribed(chalkKey: string, call: untyped) =
  if isSubscribedKey(chalkKey):
    let arr = call

    if len(arr) != 0:
      result[chalkKey] = pack(arr)

template loadAsIsKeyFromCacheIfSubscribed(chalkKey, cacheKey: string) =
  if isSubscribedKey(chalkKey) and cacheKey in psInfo:
    setIfNotEmpty(result, chalkKey, psInfo[cacheKey])

template loadIntKeyFromCacheIfSubscribed(chalkKey, cacheKey: string) =
  if isSubscribedKey(chalkKey) and cacheKey in psInfo:
    result[chalkKey] = pack(parseInt(psInfo[cacheKey]))

template loadFloatKeyFromCacheIfSubscribed(chalkKey, cacheKey: string) =
  if isSubscribedKey(chalkKey) and cacheKey in psInfo:
    result[chalkKey] = pack(parseFloat(psInfo[cacheKey]))

template loadIntArrKeyFromCacheIfSubscribed(chalkKey, cacheKey: string) =
  if isSubscribedKey(chalkKey) and cacheKey in psInfo:
    let
      json = parseJson(psInfo[cacheKey])
      x    = to(json, seq[int])

    result[chalkKey] = pack(x)

template loadStrKeyFromCacheOrCall(chalkKey, cacheKey: string, call: untyped) =
  if isSubscribedKey(chalkKey):
    if cacheKey in psInfo:
      setIfNotEmpty(result, chalkKey, psInfo[cacheKey])
    else:
      setIfNotEmpty(result, chalkKey, call)

template loadArrKeyFromCacheOrCall(chalkKey, cacheKey: string, call: untyped) =
  if isSubscribedKey(chalkKey):
    if cacheKey in psInfo:
      setIfNotEmpty(result, chalkKey, psInfo[cacheKey])
    else:
      let val = call
      if  val != "":
        let
          json = parseJson(val)
          x    = to(json, seq[string])

        result[chalkKey] = pack(x)

proc procfsGetRunTimeArtifactInfo(self: Plugin, obj: ChalkObj, ins: bool):
                                 ChalkDict {.cdecl.} =
  result    = ChalkDict()
  let cache = ProcFsCache(self.internalState)

  if obj.pid.isNone():
    return

  let
    pid         = int(obj.pid.get())
    pidAsString = $(pid)

  var psInfo: ProcDict

  if isSubscribedKey("_PROCESS_PID"):
    result["_PROCESS_PID"] = pack(pid)

  if cache.psInfoCache.isSome():
    let cache = cache.psInfoCache.get()
    if pidAsString notin cache:
      return
    psInfo = cache[pidAsString]

  if isSubscribedKey("_PROCESS_DETAIL"):
    if psInfo == nil:
      psInfo = pidAsString.getFullProcessInfo()
  elif psInfo == nil:
    psInfo = ProcDict()

  if isSubscribedKey("_PROCESS_PARENT_PID") or
     isSubscribedKey("_PROCESS_START_TIME") or
     isSubscribedKey("_PROCESS_STATE") or
     isSubscribedKey("_PROCESS_PGID") or
     isSubscribedKey("_PROCESS_UTIME") or
     isSubscribedKey("_PROCESS_STIME") or
     isSubscribedKey("_PROCESS_CHILDREN_UTIME") or
     isSubscribedKey("_PROCESS_CHILDREN_STIME") or
     isSubscribedKey("_PROCESS_DETAIL"):

    if "ppid" notin psInfo:
      pidAsString.getPidStatInfo(psInfo)

  if isSubscribedKey("_PROCESS_UMASK") or
     isSubscribedKey("_PROCESS_UID") or
     isSubscribedKey("_PROCESS_GID") or
     isSubscribedKey("_PROCESS_NUM_FD_SIZE") or
     isSubscribedKey("_PROCESS_GROUPS") or
     isSubscribedKey("_PROCESS_SECCOMP_STATUS") or
     isSubscribedKey("_PROCESS_DETAIL"):
    if "umask" notin psInfo:
      pidAsString.getPidStatusInfo(psInfo)

  loadArrKeyFromCacheOrCall("_PROCESS_ARGV", "argv", pidAsString.getPidArgv())
  loadStrKeyFromCacheOrCall("_PROCESS_CWD", "cwd", pidAsString.getPidCwd())
  loadStrKeyFromCacheOrCall("_PROCESS_EXE_PATH", "path",
                         pidAsString.getPidExePath())
  loadStrKeyFromCacheOrCall("_PROCESS_COMMAND_NAME", "command",
                         pidAsString.getPidCommandName())

  loadIntKeyFromCacheIfSubscribed("_PROCESS_PARENT_PID", "ppid")
  loadIntKeyFromCacheIfSubscribed("_PROCESS_PGID", "pgrp")
  loadIntKeyFromCacheIfSubscribed("_PROCESS_UMASK", "umask")
  loadIntKeyFromCacheIfSubscribed("_PROCESS_NUM_FD_SIZE", "fdsize")
  loadFloatKeyFromCacheIfSubscribed("_PROCESS_START_TIME", "runtime")
  loadFloatKeyFromCacheIfSubscribed("_PROCESS_UTIME", "user_time")
  loadFloatKeyFromCacheIfSubscribed("_PROCESS_STIME", "system_time")
  loadFloatKeyFromCacheIfSubscribed("_PROCESS_CHILDREN_UTIME", "child_utime")
  loadFloatKeyFromCacheIfSubscribed("_PROCESS_CHILDREN_STIME", "child_stime")
  loadIntArrKeyFromCacheIfSubscribed("_PROCESS_UID", "uid")
  loadIntArrKeyFromCacheIfSubscribed("_PROCESS_GID", "gid")
  loadIntArrKeyFromCacheIfSubscribed("_PROCESS_GROUPS", "groups")
  loadAsIsKeyFromCacheIfSubscribed("_PROCESS_STATE", "state")
  loadAsIsKeyFromCacheIfSubscribed("_PROCESS_SECCOMP_STATUS", "seccomp")

  # These are not loaded in other contexts, and don't go into the cache.
  loadDictKeyIfSubscribed("_PROCESS_FD_INFO",   pidAsString.getFdInfo())
  loadArrKeyIfSubscribed("_PROCESS_MOUNT_INFO", pidAsString.getMountInfo())

  if isSubscribedKey("_PROCESS_DETAIL"):
    result["_PROCESS_DETAIL"] = pack(psInfo)


proc loadProcFs*() =
  when hostOs == "linux":
    newPlugin("procfs",
              rtHostCallback = RunTimeHostCb(procfsGetRunTimeHostInfo),
              rtArtCallback  = RunTimeArtifactCb(procfsGetRunTimeArtifactInfo),
              cache          = RootRef(ProcFsCache()))
