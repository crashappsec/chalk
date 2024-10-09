##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[net]
import ".."/[config, plugin_api, pingttl]

proc getTtlIps(): Box =
  var data = newTable[string, seq[string]]()
  # pingttl is only implemented for linux
  when hostOs == "linux":
    let
      ipHops    = attrGet[TableRef[string, int]]("network.partial_traceroute_ips")
      timeoutMs = attrGet[int]("network.partial_traceroute_timeout_ms")
    for dest, hops in ipHops:
      var
        route = newSeq[string]()
        anyIp = false
      for ttl in countup(1, hops):
        let ip = tryGetIpForTTL(parseIpAddress(dest), ttl = ttl, timeoutMs = timeoutMs)
        if ip.isSome():
          route.add($(ip.get()))
          anyIp = true
        else:
          # ensure route list has all hops even if we could not detect intermediate IP
          route.add("")
      if anyIp:
        data[dest] = route
  return pack(data)

proc networkGetRunTimeHostInfo*(self: Plugin,
                                objs: seq[ChalkObj]):
                               ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_NETWORK_PARTIAL_TRACEROUTE_IPS", getTtlIps())

proc loadNetwork*() =
  newPlugin("network",
            rtHostCallback = RunTimeHostCb(networkGetRunTimeHostInfo))
