##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import pkg/[
  nimutils,
]
import "."/[
  tables,
]

export tables

type ChalkDict* = OrderedTableRef[string, Box]

proc update*(self: ChalkDict, other: ChalkDict): ChalkDict {.discardable.} =
  result = self
  for k, v in other:
    self[k] = v

proc merge*(self: ChalkDict, other: ChalkDict, deep = false): ChalkDict {.discardable.} =
  result = self
  for k, v in other:
    if k in self and self[k].kind == MkSeq and v.kind == MkSeq:
      for i in v:
        if i notin self[k]:
          self[k].add(i)
    elif k in self and self[k].kind == MkTable and v.kind == MkTable:
      let
        mine   = unpack[ChalkDict](self[k])
        theirs = unpack[ChalkDict](v)
      if deep:
        mine.merge(theirs)
      else:
        for kk, vv in theirs:
          mine[kk] = vv
      self[k] = pack(mine)
    else:
      self[k] = v

proc nestWith*(self: ChalkDict, key: string): ChalkDict =
  result = ChalkDict()
  for k, v in self:
    let value = ChalkDict()
    value[key] = v
    result[k] = pack(value)
