##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

##
## FD cache
## Global cache for opened files
##
## The overall concept is that there is a global cache
## for all opened file streams.
##
## Some things you can do:
## * yield   - create or get existing file stream from cache.
##             Analogy is getting connection from pool.
## * release - release file stream back into the cache.
##             Analogy is release connection back into pool.
## * close   - close file stream and delete from the cache.
##             Analogy is closing connection.
##             This should be used only in specific places where
##             FD needs to be explicitly closed such as when overwriting
##             a content of a file.
##
## To fascilitate above operations, the cache is
## * limited to a specific size
## * it keeps track of all the users of a specific file stream
## * when cache reaches its limit size, it closes LRU file streams
##

# TODO move this to nimutils

import std/[enumerate, posix, streams, tables]

# ----------------------------------------------------------------------------

proc getOpenLimit(): int =
  var limit: RLimit
  let success = getrlimit(RLIMIT_NOFILE, limit)
  if success != 0:
    raise newException(OSError, "Could not determine open file limit")
  return limit.rlim_cur

proc openFileStream(path: string, mode = fmReadWriteExisting): FileStream =
  var stream = newFileStream(path, mode = mode)
  if stream == nil:
    stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(OSError, path & ": cannot open for either reading/reading+writing")
  return stream

# ----------------------------------------------------------------------------

type FDStream = ref object
    path:     string
    stream:   FileStream
    refCount: int

proc newStream(path: string, mode = fmReadWriteExisting): FDStream =
  return FDStream(
    path:   path,
    stream: openFileStream(path, mode = mode),
  )

proc yieldStream(self: FDStream, seek = 0): FileStream =
  if seek >= 0:
    self.stream.setPosition(seek)
  self.refCount += 1
  result = self.stream

proc releaseStream(self: FDStream) =
  self.refCount -= 1
  if self.refCount < 0:
    raise newException(ValueError, self.path & ": FD was released more times than yielded")

proc closeStream(self: FDStream) =
  self.stream.close()

proc isUsed(self: FDStream): bool =
  return self.refCount > 0

# ----------------------------------------------------------------------------

type FDCache = ref object
    size: int
    byPath: OrderedTable[string, FDStream]
    byStream: Table[FileStream, string]

proc `[]`(self: FDCache, path: string): FDStream =
  if path notin self.byPath:
    raise newException(KeyError, path & ": not in FD cache")
  return self.byPath[path]

proc `[]`(self: FDCache, fs: FileStream): FDStream =
  if fs notin self.byStream:
    raise newException(KeyError, "file stream not in FD cache")
  let path = self.byStream[fs]
  return self[path]

proc `[]=`(self: FDCache, path: string, stream: FDStream) =
  self.byPath[path] = stream
  self.byStream[stream.stream] = path

proc contains(self: FDCache, path: string): bool =
  return path in self.byPath

proc contains(self: FDCache, stream: FileStream): bool =
  return stream in self.byStream

proc del(self: FDCache, stream: FDStream) =
  self.byPath.del(stream.path)
  self.byStream.del(stream.stream)

proc len(self: FDCache): int =
  return len(self.byPath)

proc newFDCache(size: int): FDCache =
  return FDCache(
    size:     size,
    byPath:   initOrderedTable[string, FDStream](),
    byStream: initTable[FileStream, string](),
  )

proc closeStream(self: FDCache, stream: FDStream) =
  stream.closeStream()
  self.del(stream)

proc closeFileStream(self: FDCache, fs: FileStream) =
  if fs in self:
    let stream = self[fs]
    self.closeStream(stream)

proc closeFileStream(self: FDCache, path: string) =
  if path in self:
    let stream = self[path]
    self.closeStream(stream)

proc evictStream(self: FDCache, stream: FDStream) =
  if stream.isUsed():
    raise newException(OSError, stream.path & ": is still being used and cannot be released from FD cache.")
  self.closeStream(stream)

proc maybeEvictLRUStreams(self: FDCache, n: int) =
  let minToEvict = len(self) - self.size + 1
  if minToEvict <= 0:
    return
  var toEvict: seq[FDStream] = @[]
  for i, stream in enumerate(self.byPath.values()):
    if i < minToEvict:
      toEvict.add(stream)
    else:
      # as we are evicting, evict everything not being used
      # to avoid lots of small evicts in favor of batch evicts
      if not stream.isUsed():
        toEvict.add(stream)
      else:
        break
  for stream in toEvict:
    self.evictStream(stream)

proc limitSize(self: FDCache, size: int) =
  self.size = size
  # if current size is already bigger, prune it
  self.maybeEvictLRUStreams(0)

proc yieldFileStream(self:  FDCache,
                     path:  string,
                     seek   = 0,
                     strict = false,
                     mode   = fmReadWriteExisting,
                     ):     FileStream =
  self.maybeEvictLRUStreams(n = 1)
  var stream: FDStream
  if path in self:
    stream = self[path]
    # re-add to maintain LRU order
    self.del(stream)
  else:
    try:
      stream = newStream(path, mode = mode)
    except:
      if strict:
        raise
      return nil
  self[path] = stream
  result = stream.yieldStream(seek = seek)

proc releaseFileStream(self: FDCache, fs: FileStream) =
  if fs != nil:
    let stream = self[fs]
    stream.releaseStream()
    stream.stream.setPosition(0)

template withFileStream(self: FDCache, path: string, strict: bool, code: untyped) =
  var stream {.inject.}: FileStream
  try:
    stream = self.yieldFileStream(path, 0, strict)
    code
  finally:
    self.releaseFileStream(stream)
    stream = nil

# ----------------------------------------------------------------------------

let
  # dont use all FDs in the cache and allow other descriptors
  # to be opened in external libs/etc
  fdLimit = getOpenLimit() div 2
  fdCache = newFDCache(size = fdLimit)

proc limitFDCacheSize*(size: int) =
  if size > fdLimit:
    raise newException(OSError,
                       "attempting to set FD cache size limit to " & $size &
                       " which is too large given system limit of " & $fdLimit)
  fdCache.limitSize(size)

proc yieldFileStream*(path:  string,
                      seek   = 0,
                      strict = false,
                      mode   = fmReadWriteExisting,
                      ):     FileStream =
  return fdCache.yieldFileStream(path   = path,
                                 seek   = seek,
                                 strict = strict,
                                 mode   = mode)

proc releaseFileStream*(fs: FileStream) =
  fdCache.releaseFileStream(fs)

proc closeFileStream*(fs: FileStream) =
  fdCache.closeFileStream(fs)

proc closeFileStream*(path: string) =
  fdCache.closeFileStream(path)

template withFileStream*(path: string, strict: bool, code: untyped) =
  fdCache.withFileStream(path, strict):
    code

# ----------------------------------------------------------------------------

when isMainModule:
  proc withCache() =
    let
      testCache = newFDCache(size = 2)
      one1       = testCache.yieldFileStream("one")
      one2       = testCache.yieldFileStream("one")
      two        = testCache.yieldFileStream("two")
    assert(one1 == one2)
    assert(one1 != two)

    try:
      # should not be allowed to yield file as one is not released
      discard testCache.yieldFileStream("three")
      assert(false)
    except:
      assert(true)

    testCache.releaseFileStream(one1)
    try:
      # should still not be allowed to yield file as one is not released
      discard testCache.yieldFileStream("three")
      assert(false)
    except:
      assert(true)

    testCache.releaseFileStream(one2)
    # we can finally get three as all ones have been released
    let three      = testCache.yieldFileStream("three")

    testCache.releaseFileStream(two)
    let one3       = testCache.yieldFileStream("one")
    assert(one1 != one3)

    testCache.releaseFileStream(three)

    testCache.withFileStream("one", strict = true):
      assert(stream != nil)
    assert(stream == nil)

  withCache()

  proc global() =
    withFileStream("one", strict = true):
      assert(stream != nil)
    assert(stream == nil)

  global()
