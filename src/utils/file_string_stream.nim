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
import pkg/[
  nimutils,
]
import "."/[
  fd_cache,
  tables,
]

export fd_cache

type
  # Type aliases to work around Nim's generic type matching limitations.
  # When using HSlice[IntA, IntB] in proc signatures, Nim requires both
  # bounds to be the exact same integer type (e.g., both int or both int64).
  # These aliases allow mixing different integer types in slices (e.g., myStream[0..len(data)])
  # where 0 is int and len() returns int64, avoiding explicit type conversions.
  # Without these aliases, users would need to write myStream[0.int..len(data)]
  IntA = SomeInteger
  IntB = SomeInteger

  EndOverride = tuple
    i:    int
    data: string

  FileStringStream* = ref object
    path*:       string
    size:        int
    loaded:      bool
    mutated:     bool
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
    # requested slice is exclusively within the endOverride range
    if self.endOverride.i >= 0 and self.endOverride.i <= int(s.a):
      let
        a = int(s.a) - self.endOverride.i
        b = int(s.b) - self.endOverride.i
      result = self.endOverride.data[a .. b]
    # otherwise we need to read section of the file
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

proc `[]`*(self: FileStringStream, s: HSlice[SomeInteger, BackwardsIndex]): string =
  result = self[int(s.a) .. len(self) - int(s.b)]

proc `[]=`*(self: FileStringStream, i: SomeInteger, c: char) =
  self.mutated = true
  if self.loaded:
    self.data[i] = c
  else:
    self.overrides[i] = c

proc `[]=`*(self: FileStringStream, i: SomeInteger, d: string) =
  self.mutated = true
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

iterator chunkPairs*(self: FileStringStream,
                     s:    HSlice[IntA, IntB],
                     size: int,
                     ): (HSlice[IntA, int], string) =
  for i in countup(int(s.a), int(s.b), size):
    let step = i .. min(i + size - 1, int(s.b))
    yield (step, self[step])

iterator chunks*(self: FileStringStream,
                 s:    HSlice[IntA, IntB],
                 size: int,
                 ): string =
  for _, chunk in self.chunkPairs(s, size):
    yield chunk

iterator chunkPairs*(self: FileStringStream,
                     s:    HSlice[IntA, BackwardsIndex],
                     size: int,
                     ): (HSlice[IntA, int], string) =
  let l = len(self)
  for i, chunk in self.chunkPairs(int(s.a) .. l - int(s.b), size):
    yield (i, chunk)

iterator chunks*(self: FileStringStream,
                 s:    HSlice[IntA, BackwardsIndex],
                 size: int,
                 ): string =
  for _, chunk in self.chunkPairs(s, size):
    yield chunk

proc readAll*(self: FileStringStream): string =
  if self.loaded:
    result = self.data
  else:
    result = self[0 ..< len(self)]

proc reset*(self: FileStringStream): FileStringStream =
  result = FileStringStream(
    path:        self.path,
    size:        self.size,
    overrides:   newTable[int, char](),
    endOverride: (-1, ""),
  )
  # there were mutations on loaded data so
  # cannot simply copy-paste but need to reread the data
  if self.mutated and self.loaded:
    result.load()
  # otherwise copy existing data as-is
  else:
    result.loaded = self.loaded
    result.data   = self.data

proc sha256Hex*(self: FileStringStream): string =
  var hash = initSha256()
  for c in self.chunks(0 .. ^1, 4096):
    hash.update(@c)
  return hash.finalHex()

proc newFileStringStream*(path: string): FileStringStream =
  let info = getFileInfo(path)
  result = FileStringStream(
    path:        path,
    size:        info.size,
    overrides:   newTable[int, char](),
    endOverride: (-1, ""),
  )

proc newLoadedFileStringStream*(data: string): FileStringStream =
  result = FileStringStream(
    loaded:      true,
    path:        "",
    data:        data,
    size:        len(data),
    overrides:   newTable[int, char](),
    endOverride: (-1, ""),
  )
