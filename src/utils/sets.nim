##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  sets,
]

export sets

proc `+`*[T](a, b: OrderedSet[T]): OrderedSet[T] =
  result = initOrderedSet[T]()
  for i in a:
    result.incl(i)
  for i in b:
    result.incl(i)
