##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[net]
import ".."/[config, plugin_api, pingttl]

proc getTtlIps(): Box =
  var data = newTable[string, TableRef[string, string]]()
  # pingttl is only implemented for linux
  when hostOs == "linux":
    let ipTTLs = attrGet[TableRef[string, seq[string]]]("network.partial_traceroute_ips")
    for dest, ttls in ipTTLs:
      var route = newTable[string, string]()
      for t in ttls:
        let ttl = parseInt(t)
        let ip  = tryGetIpForTTL(parseIpAddress(dest), ttl = ttl)
        if ip.isSome():
          route[t] = $(ip.get())
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
