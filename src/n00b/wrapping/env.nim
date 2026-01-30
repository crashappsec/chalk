import std/options

import ".."/[
  types,
]
import "."/[
  string,
]

export types

proc n00b_get_env(
  name: ptr n00b_string_t,
): ptr n00b_string_t {.header:"n00b/core.h".}

proc n00b_set_env(
  name:  ptr n00b_string_t,
  value: ptr n00b_string_t,
) {.header:"n00b/core.h".}

proc n00b_remove_env(
  name: ptr n00b_string_t,
): bool {.header:"n00b/core.h".}

proc n00bGetEnv*(name: system.string): Option[system.string] =
  let value = n00b_get_env(@name)
  if value == nil:
    return none[system.string]()
  return some($value)

proc n00bSetEnv*(name: system.string, value: system.string) =
  n00b_set_env(@name, @value)

proc n00bRemoveEnv*(name: system.string): bool =
  return n00b_remove_env(@name)
