##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Pull metadata from the proc file system on Linux.

import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/json,
  utils/proc_load,
  utils/proc_net,
  utils/proc_pid,
]

proc getPsAllInfo(): JsonNode =
  result = newJObject()
  for p in iterAllProcs():
    p.loadFull()
    result[$p.pid] = p.asJson()

proc procfsGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
       ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_TCP_SOCKET_INFO", getTCPSockInfo())
  result.setIfNeeded("_OP_UDP_SOCKET_INFO", getUDPSockInfo())
  result.setIfNeeded("_OP_ARP_TABLE",       getArpTable())
  result.setIfNeeded("_OP_IPV4_ROUTES",     getIPv4Routes())
  result.setIfNeeded("_OP_IPV4_INTERFACES", getIPv4Interfaces())
  result.setIfNeeded("_OP_IPV6_ROUTES",     getIPv6Routes())
  result.setIfNeeded("_OP_IPV6_INTERFACES", getIPv6Interfaces())
  result.setIfNeeded("_OP_ALL_PS_INFO",     getPsAllInfo().nimJsonToBox())
  result.setIfNeeded("_OP_CPU_INFO",        getLoadInfo().nimJsonToBox())

proc procfsGetRunTimeArtifactInfo(self: Plugin, obj: ChalkObj, ins: bool):
                                 ChalkDict {.cdecl.} =
  result    = ChalkDict()
  if obj.pid.isNone():
    return

  let info = getOrNewProc(obj.pid.get())

  result.setIfNeeded("_PROCESS_PID",            info.pid)
  result.setIfNeeded("_PROCESS_ARGV",           info.loadArgv().argv)
  result.setIfNeeded("_PROCESS_CWD",            info.loadCwd().cwd)
  result.setIfNeeded("_PROCESS_EXE_PATH",       info.loadPath().path)
  result.setIfNeeded("_PROCESS_COMMAND_NAME",   info.loadCommand().command)

  result.setIfNeeded("_PROCESS_PARENT_PID",     info.loadStats().ppid)
  result.setIfNeeded("_PROCESS_PGID",           info.loadStats().pgrp)
  result.setIfNeeded("_PROCESS_START_TIME",     info.loadStats().runtime)
  result.setIfNeeded("_PROCESS_UTIME",          info.loadStats().user_time)
  result.setIfNeeded("_PROCESS_STIME",          info.loadStats().system_time)
  result.setIfNeeded("_PROCESS_CHILDREN_UTIME", info.loadStats().child_utime)
  result.setIfNeeded("_PROCESS_CHILDREN_STIME", info.loadStats().child_stime)
  result.setIfNeeded("_PROCESS_STATE",          info.loadStats().state)

  result.setIfNeeded("_PROCESS_UMASK",          info.loadStatus().umask)
  result.setIfNeeded("_PROCESS_UID",            info.loadStatus().uid)
  result.setIfNeeded("_PROCESS_GID",            info.loadStatus().gid)
  result.setIfNeeded("_PROCESS_NUM_FD_SIZE",    info.loadStatus().fdsize)
  result.setIfNeeded("_PROCESS_GROUPS",         info.loadStatus().groups)
  result.setIfNeeded("_PROCESS_SECCOMP_STATUS", info.loadStatus().seccomp)

  result.setIfNeeded("_PROCESS_FD_INFO",        info.loadFdInfo().fds)
  result.setIfNeeded("_PROCESS_MOUNT_INFO",     info.loadMountInfo().mounts)
  result.setIfNeeded("_PROCESS_DETAIL",         info.loadFull().asJson().nimJsonToBox())

proc loadProcFs*() =
  when hostOS == "linux":
    newPlugin("procfs",
              rtHostCallback = RunTimeHostCb(procfsGetRunTimeHostInfo),
              rtArtCallback  = RunTimeArtifactCb(procfsGetRunTimeArtifactInfo),
              )
