##
## Copyright (c) 2024, Crash Override, Inc.
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

import std/[algorithm, bitops, enumerate, net, strutils]
import "."/[util]

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
    ma   = if same >  64: 0'u64        else: high(uint64) shr same
    mb   = if same <= 64: high(uint64) else: high(uint64) shr (same - 64)
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
