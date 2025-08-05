##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  streams,
  posix
]
import "."/[
  fd_cache,
  tables,
]

export fd_cache

type
  # alias to allow using different ints in the same function signature generic
  # as otherwise nim doesnt match signature
  IntA = SomeInteger
  IntB = SomeInteger

  EndOverride = tuple
    i:    int
    data: string

  FileStringStream* = ref object
    path:        string
    size:        int
    loaded:      bool
    data:        string
    overrides:   TableRef[int, char]
    endOverride: EndOverride

template withFileStream(self: FileStringStream, code: untyped) =
  withFileStream(self.path, mode = fmRead, strict = true):
    code

proc load*(self: FileStringStream) =
  if not self.loaded:
    self.withFileStream:
      self.data   = stream.readAll()
      self.loaded = true

proc len*(self: FileStringStream): int =
  if self.loaded:
    return len(self.data)
  elif self.endOverride.i < 0:
    result = self.size
  else:
    result = self.endOverride.i + len(self.endOverride.data)

proc `[]`*(self: FileStringStream, s: HSlice[IntA, IntB]): string =
  if self.loaded:
    result = self.data[s]
  else:
    self.withFileStream:
      stream.setPosition(int(s.a))
      let n = int(s.b) - int(s.a) + 1
      result = stream.readStr(n)
      for i, o in self.overrides.pairs():
        if i >= int(s.a) and i <= int(s.b):
          result[i - int(s.a)] = o
      if self.endOverride.i >= int(s.a) and self.endOverride.i <= int(s.b):
        let
          a = self.endOverride.i - int(s.a)
          l = n - a
        result = result[0 ..< a] & self.endOverride.data[0 ..< l]
      elif self.endOverride.i >= 0 and self.endOverride.i < int(s.a):
        let
          a = int(s.a) - self.endOverride.i
          b = int(s.b) - self.endOverride.i
        result = self.endOverride.data[a .. b]

proc `[]`*(self: FileStringStream, s: HSlice[SomeInteger, BackwardsIndex]): string =
  result = self[int(s.a) .. len(self) - int(s.b)]

proc `[]=`*(self: FileStringStream, i: SomeInteger, c: char) =
  if self.loaded:
    self.data[i] = c
  else:
    self.overrides[i] = c

proc `[]=`*(self: FileStringStream, i: SomeInteger, d: string) =
  if self.loaded:
    self.data = self.data[0 ..< i] & d
  else:
    self.endOverride = (int(i), d)
    var toCleanUp = newSeq[int]()
    for j, _ in self.overrides.pairs():
      if j >= int(i):
        toCleanUp.add(j)
    for j in toCleanUp:
      self.overrides.del(j)

proc readInt*[T](self: FileStringStream, where: int): T =
  let value =
    if self.loaded:
      self.data[where ..< where + sizeof(T)]
    else:
      self[where ..< where + sizeof(T)]
  result = cast[ref T](addr value[0])[]

proc readAll*(self: FileStringStream): string =
  if self.loaded:
    result = self.data
  else:
    result = self[0 ..< len(self)]

proc writeAll*(self: FileStringStream, s: string) =
  self.data   = s
  self.loaded = true

proc copy*(self: FileStringStream): FileStringStream =
  result = FileStringStream(
    loaded:      self.loaded,
    data:        self.data,
    path:        self.path,
    size:        self.size,
    overrides:   newTable[int, char](),
    endOverride: (-1, ""),
  )

proc newFileStringStream*(path: string): FileStringStream =
  let info = getFileInfo(path)
  result = FileStringStream(
    path:        path,
    size:        info.size,
    overrides:   newTable[int, char](),
    endOverride: (-1, ""),
  )
