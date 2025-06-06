##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  tables,
]

export tables

proc copy*[A, B](data: TableRef[A, B]): TableRef[A, B] =
  result = newTable[A, B]()
  for k, v in data:
    result[k] = v

proc popOrDefault*[A, B](data: TableRef[A, B], key: A, default: B): B =
  result = data.getOrDefault(key, default)
  data.del(key)
