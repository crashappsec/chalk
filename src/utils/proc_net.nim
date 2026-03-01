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

proc portFromHex(s: string): string =
  try:
    return $(fromHex[uint16](s))
  except:
    return ""

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

proc getIPv6Interfaces*(): TableRef[string, seq[string]] =
  result = newTable[string, seq[string]]()
  let contentOpt = loadStringArrayTable(Path("/proc/net/if_inet6"))
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 4:
      return
    result[row[^1]] = @[ipv6FromHex(row[0])] & row[1 .. ^2]

proc getIPv4Routes*(): ProcStringArrayTable =
  let contentOpt  = loadStringArrayTable(Path("/proc/net/route"))
  if contentOpt.isNone():
    return
  for row in contentOpt.get()[1..^1]:
    if len(row) < 11:
      continue
    result.add(@[
      ipv4FromHex(row[1]), # destination
      ipv4FromHex(row[2]), # gateway
      ipv4FromHex(row[7]), # mask
      row[0],              # interface
      row[3],              # flags
      row[4],              # reference count
      row[5],              # use
      row[6],              # metric/priority
      row[8],              # mtu
      row[9],              # window
      row[10],             # irtt
    ])

proc getIPv6Routes*(): ProcStringArrayTable =
  let contentOpt  = loadStringArrayTable(Path("/proc/net/ipv6_route"))
  if contentOpt.isNone():
    return
  for row in contentOpt.get():
    if len(row) < 10:
      continue
    # Reorder to make it more consistent wrt. IPV4 output
    result.add(@[
      ipv6FromHex(row[0]), # destination
      row[1],              # destination prefix len
      ipv6FromHex(row[2]), # source
      row[3],              # source prefix len
      ipv6FromHex(row[4]), # gateway
      row[9],              # interface
      row[8],              # flags
      row[6],              # reference count
      row[7],              # use
      row[5],              # metric
    ])

proc getArpTable*(): ProcStringArrayTable =
  let contentOpt  = loadStringArrayTable(Path("/proc/net/arp"))
  if contentOpt.isNone():
    return
  if len(contentOpt.get()) < 2:
    return
  return contentOpt.get()[1..^1]

proc getSockInfo(raw: string, mapStatus: Table[string, string]): ProcStringArrayTable =
  let lines = raw.strip().splitLines()
  if len(lines) < 2:
    return
  for line in lines[1 .. ^1]:
    let parts = line.splitWhitespace()
    if len(parts) < 10:
      continue
    let
      (localIpHex, localPortHex)   = parts[1].splitBy(":")
      (remoteIpHex, remotePortHex) = parts[2].splitBy(":")
    # e.g.:
    # sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
    #  0: 0100007F:9CEF 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 898678867 1 000000007e4af501 100 0 0 10 0
    #  0  1             2             3  4                 5           6            7        8 9
    result.add(@[
      ipv4FromHex(localIpHex),
      portFromHex(localPortHex),
      ipv4FromHex(remoteIpHex),
      portFromHex(remotePortHex),
      mapStatus.getOrDefault(parts[3], mapStatus[""]),
      parts[7],   # uid
      parts[9],   # inode
    ])

proc filterSockInfo(data:   ProcStringArrayTable,
                    config: string,
                    ): ProcStringArrayTable =
  let statuses = attrGet[seq[string]](config)
  result = @[]
  for i in data:
    if len(i) < 5:
      continue
    let status = i[4]
    if status in statuses or "*" in statuses:
      result.add(i)

proc getTCPSockInfo*(): ProcStringArrayTable =
    return filterSockInfo(
      getSockInfo(
        tryToLoadFile("/proc/net/tcp"),
        tcpStatusMap,
      ),
      "network.tcp_socket_statuses",
    )

proc getUDPSockInfo*(): ProcStringArrayTable =
    return getSockInfo(
      tryToLoadFile("/proc/net/udp"),
      udpStatusMap,
    )
