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
    let ipHops = attrGet[TableRef[string, int]]("network.partial_traceroute_ips")
    for dest, hops in ipHops:
      var route = newSeq[string]()
      for ttl in countup(1, hops):
        let ip  = tryGetIpForTTL(parseIpAddress(dest), ttl = ttl)
        route.add($(ip.get()))
      if len(route) > 0:
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
