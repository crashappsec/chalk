##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/utils/json
import "../docker"/[dockerfile, ids]
import "./binding"

type
  BaseExec* = object
    entrypoint*: JsonNode
    cmd*:        JsonNode
    platform*:   DeclaredPlatform
    binding*:    BaseBinding

  StartupPlan* = object
    entrypoint*:    JsonNode
    cmd*:           JsonNode
    alreadyWrapped*: bool
    emitCmd*:       bool
    platform*:      DeclaredPlatform
    binding*:       BaseBinding

  StartupPlanResultKind* = enum
    sprPlan,
    sprRefuse

  StartupPlanResult* = object
    case kind*: StartupPlanResultKind
    of sprPlan:
      plan*: StartupPlan
    of sprRefuse:
      discard

proc isChalkExecEntrypoint(entrypoint: JsonNode): bool =
  ## Mirrors docker/entrypoint.nim: an entrypoint we already wrapped, or one
  ## inherited from a chalked base image, begins with `/chalk exec`.
  if entrypoint == nil or entrypoint.kind != JArray or len(entrypoint) < 2:
    return false
  return entrypoint[0].getStr() == "/chalk" and entrypoint[1].getStr() == "exec"

proc resolveValue(value: StartupValue, inherited: JsonNode): JsonNode =
  case value.kind
  of svInherited:
    return inherited
  of svAbsent:
    return nil
  of svExec:
    return value.argv
  of svShell:
    # Podman 5.8.2 / Buildah 1.43.1 uses the platform default here. SHELL
    # affects RUN, but imagebuilder's CMD and ENTRYPOINT dispatchers hardcode
    # /bin/sh -c for Linux startup instructions.
    return defaultShellJson & `%`(@[value.command])

proc planStartup*(config: FinalExecConfig,
                  root: BaseExec): StartupPlanResult =
  let
    entrypoint = resolveValue(config.entrypoint, root.entrypoint)
    cmd        = resolveValue(config.cmd, root.cmd)

  if entrypoint == nil and cmd == nil:
    return StartupPlanResult(kind: sprRefuse)

  let alreadyWrapped = isChalkExecEntrypoint(entrypoint)
  return StartupPlanResult(
    kind: sprPlan,
    plan: StartupPlan(
      entrypoint:     entrypoint,
      cmd:            cmd,
      alreadyWrapped: alreadyWrapped,
      emitCmd:        not alreadyWrapped and cmd != nil and
                      (entrypoint != nil or not config.cmdInFinal),
      platform:       root.platform,
      binding:        root.binding,
    ),
  )
