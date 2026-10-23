##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Immutable base operand selected before a Podman build is instrumented.

import std/strutils

type
  BaseBindingKind* = enum
    bbUnbound,
    bbScratch,
    bbConfigId,
    bbRegistryDigest

  BaseBinding* = object
    case kind*: BaseBindingKind
    of bbUnbound, bbScratch:
      discard
    of bbConfigId:
      configId*: string
    of bbRegistryDigest:
      reference*:     string
      imageId*:       string
      proofPlatform*: string

proc operand*(binding: BaseBinding): string =
  case binding.kind
  of bbConfigId:
    return binding.configId
  of bbRegistryDigest:
    return binding.reference
  of bbUnbound, bbScratch:
    return ""

proc validConfigId*(value: string): bool =
  if len(value) != 64:
    return false
  for c in value:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  return true

proc validBinding*(binding: BaseBinding): bool =
  case binding.kind
  of bbUnbound:
    return false
  of bbScratch:
    return true
  of bbConfigId:
    return validConfigId(binding.configId)
  of bbRegistryDigest:
    let marker = binding.reference.rfind("@sha256:")
    return marker > 0 and
           binding.reference.find('@') == marker and
           validConfigId(binding.reference[marker + "@sha256:".len .. ^1]) and
           validConfigId(binding.imageId) and
           binding.proofPlatform == "linux/amd64"
