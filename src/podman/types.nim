##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/options
import "../docker"/dockerfile
import "../types" as chalk_types
import "./exec"
import "./chalk_platform"
import "./notice"

type
  PodmanRouteKind* = enum
    prPassThrough, prInstrument, prPush, prPull

  BasePullPolicy* = enum
    bppMissing,
    bppNever,
    bppAlways,
    bppNewer

  PodmanConfidentialArg* = object
    flag*:  string
    value*: string

  PodmanBuildSpec* = object
    originalArgs*:          seq[string]
    reportArgs*:            seq[string]
    confidentialArgs*:      seq[PodmanConfidentialArg]
    contextArg*:            string
    containerfileArg*:      string
    tags*:                  seq[string]
    requestedPlatform*:     Option[ChalkPlatform]
    imageFormat*:           string
    quietOutput*:           bool
    target*:                string
    customerIidFile*:       string
    contextNames*:          seq[string]
    pullPolicy*:            BasePullPolicy
    fileValueIndex*:        int
    fileEqualsPrefix*:      string
    contextIndex*:          int
    dashDashIndex*:         int
    resolvedContext*:       string
    resolvedContainerfile*: string
    containerfileText*:     string
    guardNoNetwork*:        bool
    startup*:               FinalExecConfig
    startupPlan*:           Option[StartupPlan]

  PodmanRoute* = object
    originalArgs*: seq[string]
    image*:        string  ## operand of a push/pull; empty otherwise
    destination*:  Option[string]  ## optional destination operand of a push
    case kind*: PodmanRouteKind
    of prPassThrough:
      skip*: Option[PodmanSkip]
    of prInstrument:
      spec*: PodmanBuildSpec
    of prPush, prPull:
      discard

  PodmanWorkspace* = object
    root*:                 string
    assetContext*:         string
    derivedContainerfile*: string
    iidFile*:              string
    contextName*:          string
    derivedText*:          string

  PodmanPublication* = object
    ## Registry reference and manifest digests from one successful push.
    reference*:   chalk_types.DockerImage
    imageDigest*: string
    listDigest*:  string

  PodmanArtifactCache* = ref object of RootRef
    publications*: seq[PodmanPublication]

  ChildEndKind* = enum
    ceExited, ceSignaled, ceSpawnFailed

  ChildResult* = object
    kind*:            ChildEndKind
    exitCode*:        int
    signal*:          int
    forwardedSignal*: int

proc primaryTag*(spec: PodmanBuildSpec): string =
  if len(spec.tags) > 0:
    return spec.tags[0]
  return ""

proc isCancellation*(r: ChildResult): bool =
  if r.forwardedSignal in {1, 2, 3, 15}:
    return true
  if r.kind == ceSignaled:
    return true
  if r.kind == ceExited and r.exitCode in {129, 130, 131, 143}:
    return true
  return false

proc cancellationExit*(r: ChildResult): int =
  if r.forwardedSignal != 0:
    return 128 + r.forwardedSignal
  if r.kind == ceSignaled and r.signal != 0:
    return 128 + r.signal
  if r.kind == ceExited:
    return r.exitCode
  return 1

proc childStatus*(r: ChildResult): int =
  case r.kind
  of ceExited:
    return r.exitCode
  of ceSignaled:
    if r.signal != 0:
      return 128 + r.signal
    return 1
  of ceSpawnFailed:
    return 127
