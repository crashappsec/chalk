##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  envvars,
]

export envvars

type EnvVar* = ref object
  name:     string
  value:    string
  previous: string
  exists:   bool

proc setEnv*(name: string, value: string): EnvVar =
  new result
  result.name     = name
  result.value    = value
  result.previous = getEnv(name)
  result.exists   = existsEnv(name)
  putEnv(name, value)

proc restore(env: EnvVar) =
  if not env.exists:
    delEnv(env.name)
  else:
    putEnv(env.name, env.previous)

proc restore(vars: seq[EnvVar]) =
  for env in vars:
    env.restore()

template withEnvRestore*(vars: seq[EnvVar], code: untyped) =
  try:
    code
  finally:
    vars.restore()

proc `$`*(vars: seq[EnvVar]): string =
  result = ""
  for env in vars:
    result &= env.name & "=" & env.value & " "
