##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

proc getOrDefault*[T](self: openArray[T], i: int, default: T): T =
  if len(self) > i:
    return self[i]
  return default
