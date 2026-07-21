##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Minimal DNS A/AAAA query client (RFC 1035) with Punycode/IDNA support.
## Supports a configurable resolver address, which getaddrinfo does not.

import std/[
  monotimes,
  net,
  nativesockets,
  posix,
  strutils,
  times,
  uri,
]
import pkg/nimutils/[
  logging,
  random,
]

type DnsQtype* = enum
  A    = 1
  AAAA = 28
  ANY  = 255

# ---------------------------------------------------------------------------
# Punycode (RFC 3492)
# ---------------------------------------------------------------------------

const
  punBase     = 36
  punTmin     = 1
  punTmax     = 26
  punSkew     = 38
  punDamp     = 700
  punInitBias = 72
  punInitN    = 128

proc punDigit(d: int): char =
  if d < 26: char(ord('a') + d)
  else:      char(ord('0') + d - 26)

proc punAdapt(delta, numPoints: int, first: bool): int =
  var d = if first: delta div punDamp else: delta div 2
  d += d div numPoints
  var k = 0
  while d > (punBase - punTmin) * punTmax div 2:
    d  = d div (punBase - punTmin)
    k += punBase
  k + (punBase - punTmin + 1) * d div (d + punSkew)

proc utf8Codepoints(s: string): seq[int] =
  var i = 0
  while i < s.len:
    let b = uint8(s[i])
    let (cp, w) =
      if   b < 0x80: (int(b),                                      1)
      elif b < 0xE0: (((int(b) and 0x1F) shl 6) or
                       (int(uint8(s[i+1])) and 0x3F),               2)
      elif b < 0xF0: (((int(b) and 0x0F) shl 12) or
                       ((int(uint8(s[i+1])) and 0x3F) shl 6) or
                       (int(uint8(s[i+2])) and 0x3F),               3)
      else:          (((int(b) and 0x07) shl 18) or
                       ((int(uint8(s[i+1])) and 0x3F) shl 12) or
                       ((int(uint8(s[i+2])) and 0x3F) shl 6) or
                       (int(uint8(s[i+3])) and 0x3F),               4)
    result.add(cp)
    i += w

proc punycodeEncode*(s: string): string =
  ## Encodes a Unicode string to Punycode (RFC 3492), without the xn-- prefix.
  let input = utf8Codepoints(s)

  var basic = 0
  for cp in input:
    if cp < 0x80:
      result.add(char(cp))
      basic += 1
  if basic > 0:
    result.add('-')

  var
    n     = punInitN
    delta = 0
    bias  = punInitBias
    h     = basic
    b     = basic

  while h < input.len:
    var m = int.high
    for cp in input:
      if cp >= n and cp < m:
        m = cp

    delta += (m - n) * (h + 1)
    n = m

    for cp in input:
      if cp < n:
        delta += 1
      elif cp == n:
        var q = delta
        var k = punBase
        while true:
          let t =
            if k <= bias + punTmin: punTmin
            elif k >= bias + punTmax: punTmax
            else: k - bias
          if q < t:
            break
          result.add(punDigit(t + (q - t) mod (punBase - t)))
          q = (q - t) div (punBase - t)
          k += punBase
        result.add(punDigit(q))
        bias = punAdapt(delta, h + 1, h == b)
        delta = 0
        h += 1

    delta += 1
    n += 1

# ---------------------------------------------------------------------------
# Hostname validation and IDNA encoding
# ---------------------------------------------------------------------------

proc toAsciiDomain*(domain: string): string =
  ## Converts `domain` to ASCII-compatible encoding (IDNA-lite).
  ## Labels with non-ASCII characters are Punycode-encoded with an xn-- prefix.
  ## Raises ValueError if any label exceeds 63 chars or the full name exceeds
  ## 253 chars (= 255 bytes in DNS wire format: each label has a length prefix
  ## byte plus content, and the name is terminated by a null byte).
  var labels: seq[string]
  for label in domain.split('.'):
    if label.len == 0:
      raise newException(
        ValueError,
        "DNS hostname contains an empty label (check for adjacent or trailing dots)",
      )
    var ascii = true
    for c in label:
      if ord(c) > 127:
        ascii = false
        break
    let encoded = if ascii: label
                  else:     "xn--" & punycodeEncode(label)
    if encoded.len > 63:
      raise newException(
        ValueError,
        "DNS label '" & encoded & "' exceeds 63-character limit",
      )
    labels.add(encoded)
  result = labels.join(".")
  if result.len > 253:
    raise newException(
      ValueError,
      "DNS hostname exceeds 253-character limit (got " & $result.len & ")",
    )

# ---------------------------------------------------------------------------
# Server address / port parsing
# ---------------------------------------------------------------------------

proc tryPort(s: string): int =
  try:
    let p = parseInt(s)
    if p in 1 .. 65535: p else: -1
  except ValueError:
    -1

proc parseServerPort*(server: string): (string, Port) =
  ## Parses "host[:port]", returning (host, port). Default port is 53.
  ## Accepted formats: "1.2.3.4", "1.2.3.4:5353", "[::1]", "[::1]:5353", "::1".
  const defaultPort = Port(53)
  let parsed = parseUri("dns://" & server)
  if not server.startsWith('['):
    # Bracketed IPv6 is valid URI syntax, so parseUri handles it correctly.
    # Bare IPv6 is not: parseUri splits on the last ':', yielding a truncated
    # hostname and a non-numeric port fragment:
    #   "::1"         -> hostname="",     port="1"
    #   "2001:db8::1" -> hostname="2001", port="db81"
    # Detect the mismatch by round-tripping: reconstruct what parseUri saw and
    # compare to the original input; inequality means it was a bare IPv6.
    let roundtrip = if parsed.port == "": parsed.hostname
                    else: parsed.hostname & ":" & parsed.port
    if parsed.hostname == "" or roundtrip != server:
      return (server, defaultPort)
  let p = tryPort(parsed.port)
  return (parsed.hostname, if p > 0: Port(p) else: defaultPort)

# ---------------------------------------------------------------------------
# DNS wire format
# ---------------------------------------------------------------------------

proc addUint16(s: var string, v: uint16) =
  s.add(char(v shr 8))
  s.add(char(v and 0xff))

proc encodeDnsName(domain: string): string =
  for label in domain.split('.'):
    if label.len == 0:
      continue
    result.add(char(label.len))
    result.add(label)
  result.add('\x00')

proc buildDnsQuery(domain: string, qtype: DnsQtype, id: uint16): string =
  result = newStringOfCap(64)
  result.addUint16(id)
  result.addUint16(0x0100)  # flags: RD=1
  result.addUint16(1)       # QDCOUNT
  result.addUint16(0)       # ANCOUNT
  result.addUint16(0)       # NSCOUNT
  result.addUint16(0)       # ARCOUNT
  result.add(encodeDnsName(domain))
  result.addUint16(uint16(qtype))
  result.addUint16(1)       # QCLASS = IN

# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

proc connectUdpSocket(host: string, port: Port): Socket =
  # Determine socket family without a resolver call when host is a literal IP.
  # For hostnames, call getaddrinfo for family detection only, then free the
  # result before creating the socket to avoid any lifetime issues.
  let family =
    try:
      if parseIpAddress(host).family == IpAddressFamily.IPv6:
        Domain.AF_INET6
      else:
        Domain.AF_INET
    except ValueError:
      var
        hints: AddrInfo
        res:   ptr AddrInfo
      hints.ai_socktype = cint(SockType.SOCK_DGRAM)
      let gaiRet = getaddrinfo(host.cstring, nil, addr hints, res)
      if gaiRet != 0 or res == nil:
        let reason = if gaiRet != 0: ": " & $gai_strerror(gaiRet) else: ""
        if res != nil:
          freeAddrInfo(res)
        raise newException(
          IOError,
          "DNS: cannot resolve server '" & host & "'" & reason,
        )
      let f =
        if res.ai_family == posix.AF_INET6:
          Domain.AF_INET6
        else:
          Domain.AF_INET
      freeAddrInfo(res)
      f
  result = newSocket(
    domain   = family,
    sockType = SockType.SOCK_DGRAM,
    protocol = Protocol.IPPROTO_UDP,
    buffered = false,
  )
  result.connect(host, port)

proc dnsLookupSystem(domain: string, qtype: DnsQtype) =
  var hints: AddrInfo
  hints.ai_family = case qtype
                    of DnsQtype.AAAA: posix.AF_INET6.cint
                    of DnsQtype.ANY:  posix.AF_UNSPEC.cint
                    else:             posix.AF_INET.cint
  var res: ptr AddrInfo
  let ret = getaddrinfo(domain.cstring, nil, addr hints, res)
  if res != nil:
    freeAddrInfo(res)
  if ret != 0:
    raise newException(
      IOError,
      "DNS lookup failed for '" & domain & "': " & $gai_strerror(ret),
    )

proc dnsLookup*(
    domain:    string,
    server:    string   = "",
    qtype:     DnsQtype = DnsQtype.A,
    timeoutMs: int      = 5000,
) =
  ## Resolves `domain` via DNS, raising ValueError on an invalid hostname or
  ## IOError on lookup failure / timeout.
  ## When `server` is empty the system resolver is used (via getaddrinfo).
  ## `server` may include a port: "8.8.8.8:5353" or "[::1]:5353".
  let ascii = toAsciiDomain(domain)
  let srv   = if server == "": "system resolver" else: server
  trace("dns: " & ascii & " via " & srv)
  if server == "":
    dnsLookupSystem(ascii, qtype)
    return

  let
    id           = secureRand[uint16]()
    (host, port) = parseServerPort(server)
    packet       = buildDnsQuery(ascii, qtype, id)

  # connect() on a UDP socket installs a kernel-level filter: only datagrams
  # from this address/port are delivered.
  let sock = connectUdpSocket(host, port)
  defer: sock.close()

  discard posix.send(
    sock.getFd(),
    cast[pointer](unsafeAddr packet[0]),
    packet.len,
    cint(0),
  )

  # Loop discarding datagrams that do not match our transaction ID.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let remaining = int(inMilliseconds(deadline - getMonoTime()))
    if remaining <= 0:
      raise newException(
        IOError,
        "DNS query timed out for '" & ascii & "'",
      )
    var fds = @[sock.getFd()]
    if selectRead(fds, remaining) == 0:
      raise newException(
        IOError,
        "DNS query timed out for '" & ascii & "'",
      )
    var response = newString(512)
    let n = sock.recv(response, 512)
    if n < 4:
      continue
    if uint8(response[0]) != uint8(id shr 8) or
       uint8(response[1]) != uint8(id and 0xff):
      continue
    let rcode = uint8(response[3]) and 0x0f
    if rcode != 0:
      raise newException(
        IOError,
        "DNS lookup failed for '" & ascii & "' (rcode=" & $rcode & ")",
      )
    break
