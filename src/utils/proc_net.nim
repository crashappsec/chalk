##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  options,
  paths,
  posix,
]
import pkg/[
  nimutils,
]
import ".."/[
  types,
]
import "."/[
  json,
  proc_base,
  strings,
  tables,
]

let
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

proc ipv4FromHex(s: string): string =
  # This currently assumes little endian.
  if len(s) < 8:
    ""
  else:
    try:
      # If we decide to support big endian platforms, reverse
      # the order of results here.
      return (
        $(fromHex[uint8](s[6 ..< 8])) & "." &
        $(fromHex[uint8](s[4 ..< 6])) & "." &
        $(fromHex[uint8](s[2 ..< 4])) & "." &
        $(fromHex[uint8](s[0 ..< 2]))
      )
    except:
      return ""

proc ipv6FromHex(s: string): string =
  if len(s) < 32:
    return
  return (
    s[0  ..< 4]  & ":" &
    s[4  ..< 8]  & ":" &
    s[8  ..< 12] & ":" &
    s[12 ..< 16] & ":" &
    s[16 ..< 20] & ":" &
    s[20 ..< 24] & ":" &
    s[24 ..< 28] & ":" &
    s[28 ..< 32]
  )

proc getIPv4Interfaces*(): TableRef[string, seq[seq[int]]] =
  result = newTable[string, seq[seq[int]]]()
  let contents = tryToLoadFile("/proc/net/dev")
  if contents == "":
    return
  var lines = contents.splitLines()
  # there are 2 header lines
  if len(lines) < 3:
    return
  for line in lines[2 .. ^1]:
    if line == "":
      continue
    let (name, statsString) = line.strip().splitBy(":")
    if statsString == "":
      continue
    var stats = newSeq[int]()
    for i in statsString.strip().splitWhitespace():
      try:
        stats.add(parseInt(i))
      except:
        break
    if len(stats) != 16:
      continue
    result[name] = @[
      stats[0..<8],  # receive:  [bytes, packets, errors, drops, fifo, frame, compressed, multicast]
      stats[8..<16], # transmit: [bytes, packets, errors, drops, fifo, colls, carrier, compressed]
    ]

proc getIPv6Interfaces*(): JsonNode =
  result = newJObject()
  let contentOpt = loadStringArrayTable(Path("/proc/net/if_inet6"), start = 0)
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 6:
      return
    let item = newJArray()
    item.add(%ipv6FromHex(row[0]))     # ip
    item.add(%fromHex[uint32](row[1])) # interface index
    item.add(%fromHex[uint8](row[2]))  # prefix length
    item.add(%fromHex[uint8](row[3]))  # scope
    item.add(%fromHex[uint32](row[4])) # flags
    result[row[^1]] = item

proc getIPv4Routes*(): JsonNode =
  result = newJArray()
  let contentOpt  = loadStringArrayTable(Path("/proc/net/route"), start = 1)
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 11:
      continue
    let item = newJArray()
    item.add(%ipv4FromHex(row[1]))      # destination
    item.add(%ipv4FromHex(row[2]))      # gateway
    item.add(%ipv4FromHex(row[7]))      # mask
    item.add(%row[0])                   # interface
    item.add(%fromHex[uint32](row[3]))  # flags
    item.add(%fromHex[int32](row[4]))   # reference count
    item.add(%fromHex[uint32](row[5]))  # use
    item.add(%fromHex[uint32](row[6]))  # metric/priority
    item.add(%fromHex[uint32](row[8]))  # mtu
    item.add(%fromHex[uint32](row[9]))  # window
    item.add(%fromHex[uint32](row[10])) # irtt
    result.add(item)

proc getIPv6Routes*(): JsonNode =
  result = newJArray()
  let contentOpt  = loadStringArrayTable(Path("/proc/net/ipv6_route"), start = 0)
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 10:
      continue
    # Reorder to make it more consistent wrt. IPV4 output
    let item = newJArray()
    item.add(%ipv6FromHex(row[0]))     # destination
    item.add(%fromHex[uint8](row[1]))  # destination prefix len
    item.add(%ipv6FromHex(row[2]))     # source
    item.add(%fromHex[uint8](row[3]))  # source prefix len
    item.add(%ipv6FromHex(row[4]))     # gateway
    item.add(%row[9])                  # interface
    item.add(%fromHex[uint32](row[8])) # flags
    item.add(%fromHex[int32](row[6]))  # reference count
    item.add(%fromHex[uint32](row[7])) # use
    item.add(%fromHex[uint32](row[5])) # metric
    result.add(item)

proc getArpTable*(): JsonNode =
  result = newJArray()
  let contentOpt  = loadStringArrayTable(Path("/proc/net/arp"), start = 1)
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 6:
      continue
    let item = newJArray()
    item.add(%row[0])                  # ip
    item.add(%fromHex[uint32](row[1])) # hw type
    item.add(%fromHex[uint32](row[2])) # flags
    item.add(%row[3])                  # mac
    item.add(%row[4])                  # mask
    item.add(%row[5])                  # interface
    result.add(item)

proc getSockInfo(raw: string, mapStatus: Table[string, string]): JsonNode =
  result = newJArray()
  let lines = raw.strip().splitLines()
  if len(lines) < 2:
    return
  for line in lines[1 .. ^1]:
    let parts = line.splitWhitespace()
    if len(parts) < 10:
      continue
    let
      (localIpHex,  localPortHex)  = parts[1].splitBy(":")
      (remoteIpHex, remotePortHex) = parts[2].splitBy(":")
    # e.g.:
    # sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
    #  0: 0100007F:9CEF 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 898678867 1 000000007e4af501 100 0 0 10 0
    #  0  1             2             3  4                 5           6            7        8 9
    let item = newJArray()
    item.add(%ipv4FromHex(localIpHex))
    item.add(%fromHex[uint16](localPortHex))
    item.add(%ipv4FromHex(remoteIpHex))
    item.add(%fromHex[uint16](remotePortHex))
    item.add(%mapStatus.getOrDefault(parts[3], mapStatus[""]))
    item.add(%parseInt(parts[7]))  # uid
    item.add(%parseInt(parts[9]))  # inode
    result.add(item)

proc filterSockInfo(data:   JsonNode,
                    config: string,
                    ): JsonNode =
  let statuses = attrGet[seq[string]](config)
  result = newJArray()
  for i in data:
    if len(i) < 5:
      continue
    let status = i[4].getStr()
    if status in statuses or "*" in statuses:
      result.add(i)

proc getTCPSockInfo*(): JsonNode =
    return filterSockInfo(
      getSockInfo(
        tryToLoadFile("/proc/net/tcp"),
        tcpStatusMap,
      ),
      "network.tcp_socket_statuses",
    )

proc getUDPSockInfo*(): JsonNode =
    return getSockInfo(
      tryToLoadFile("/proc/net/udp"),
      udpStatusMap,
    )
