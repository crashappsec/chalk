##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## utils for working with ip addresses,
## specifically parse and compare ip ranges from cidr notation
##
## as nim does not support uint128 each ip address is broken down
## into a 2-tuple of (uint64, uint64) which then allows
## to compare whether its within a range of other ip tuples
## by using normal nim tuple operators
## which means all this module needs to implement is:
## * ipaddress to int-tuple conversion
## * cidr to ip range (tuple of ip-tuples)

import std/[
  algorithm,
  bitops,
  enumerate,
  net,
]
import "."/[
  strings,
]

type
  IpInt   = (uint64, uint64)
  IpRange = (IpInt, IpInt)

proc toInt(self: openArray[uint8]): uint64 =
  result = 0
  for i, n in enumerate(self.reversed()):
    result = bitor(result, rotateLeftBits(uint64(n), 8 * i))

proc toInt(self: IpAddress): IpInt =
  if self.family == IPv6:
    result = (self.address_v6[0..7].toInt(), self.address_v6[8..15].toInt())
  else:
    result = (0, self.address_v4.toInt())
  # echo($self, " ", result[0].toHex(), " " , result[1].toHex())

proc ipRange*(self: IpAddress, bits: uint): IpRange =
  if bits == 0:
    return ((0, 0), (high(uint64), high(uint64)))
  let
    same = bits + (if self.family == IPv6: 0 else: 96)
    ip   = self.toInt()
  if same > 128:
    raise newException(ValueError, "invalid cidr bit range " & $self & "/" & $bits)
  elif same == 128:
    return (ip, ip)
  let
    a, b = ip
    ma   = if same >= 64: 0'u64        else: high(uint64) shr same
    mb   = if same <  64: high(uint64) else: high(uint64) shr (same - 64)
  result = (
    (a[0].clearMasked(ma), b[1].clearMasked(mb)),
    (a[0].setMasked(ma),   b[1].setMasked(mb)),
  )
  # echo("bits: ", bits, " same: ", same)
  # echo("mask: ", ma.toHex(), " ", mb.toHex())
  # echo("low:  ", result[0][0].toHex(), " ", result[0][1].toHex())
  # echo("high: ", result[1][0].toHex(), " ", result[1][1].toHex())

proc parseIpCidr*(self: string): tuple[ip: IpAddress, range: IpRange] =
  let (maybeIp, suffix) = self.splitBy("/")
  if suffix == "":
    raise newException(ValueError, "Invalid IP CIDR " & self)
  let
    ip   = parseIpAddress(maybeIp)
    bits = parseUInt(suffix)
  return (ip, ip.ipRange(bits))

proc parseIpCidrRange*(self: string): IpRange =
  let (_, range) = self.parseIpCidr()
  return range

proc contains*(ipRange: IpRange, self: IpAddress): bool =
  let
    n           = self.toInt()
    (low, high) = ipRange
  return n >= low and n <= high

let
  specialPurposeIpv4 = @[
    # https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml
    "0.0.0.0/8".parseIpCidrRange(),
    "0.0.0.0/32".parseIpCidrRange(),
    "10.0.0.0/8".parseIpCidrRange(),
    "100.64.0.0/10".parseIpCidrRange(),
    "127.0.0.0/8".parseIpCidrRange(),
    "169.254.0.0/16".parseIpCidrRange(),
    "172.16.0.0/12".parseIpCidrRange(),
    "192.0.0.0/24".parseIpCidrRange(),
    "192.0.0.0/29".parseIpCidrRange(),
    "192.0.0.8/32".parseIpCidrRange(),
    "192.0.0.9/32".parseIpCidrRange(),
    "192.0.0.10/32".parseIpCidrRange(),
    "192.0.0.170/32".parseIpCidrRange(),
    "192.0.0.171/32".parseIpCidrRange(),
    "192.0.2.0/24".parseIpCidrRange(),
    "192.31.196.0/24".parseIpCidrRange(),
    "192.52.193.0/24".parseIpCidrRange(),
    "192.88.99.0/24".parseIpCidrRange(),
    "192.168.0.0/16".parseIpCidrRange(),
    "192.175.48.0/24".parseIpCidrRange(),
    "198.18.0.0/15".parseIpCidrRange(),
    "198.51.100.0/24".parseIpCidrRange(),
    "203.0.113.0/24".parseIpCidrRange(),
    "240.0.0.0/4".parseIpCidrRange(),
    "255.255.255.255/32".parseIpCidrRange(),
  ]
  specialPurposeIpv6 = @[
    # https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml
    "::1/128".parseIpCidrRange(),
    "::/128".parseIpCidrRange(),
    "::ffff:0:0/96".parseIpCidrRange(),
    "64:ff9b::/96".parseIpCidrRange(),
    "64:ff9b:1::/48".parseIpCidrRange(),
    "100::/64".parseIpCidrRange(),
    "100:0:0:1::/64".parseIpCidrRange(),
    "2001::/23".parseIpCidrRange(),
    "2001::/32".parseIpCidrRange(),
    "2001:1::1/128".parseIpCidrRange(),
    "2001:1::2/128".parseIpCidrRange(),
    "2001:1::3/128".parseIpCidrRange(),
    "2001:2::/48".parseIpCidrRange(),
    "2001:3::/32".parseIpCidrRange(),
    "2001:4:112::/48".parseIpCidrRange(),
    "2001:10::/28".parseIpCidrRange(),
    "2001:20::/28".parseIpCidrRange(),
    "2001:30::/28".parseIpCidrRange(),
    "2001:db8::/32".parseIpCidrRange(),
    "2002::/16".parseIpCidrRange(),
    "2620:4f:8000::/48".parseIpCidrRange(),
    "3fff::/20".parseIpCidrRange(),
    "5f00::/16".parseIpCidrRange(),
    "fc00::/7".parseIpCidrRange(),
    "fe80::/10".parseIpCidrRange(),
  ]

proc isSpecialPurpose*(self: IpAddress): bool =
  let ranges =
    if self.family == IPv6:
      specialPurposeIpv6
    else:
      specialPurposeIpv4
  for i, special in ranges:
    if self in special:
      return true
  return false
