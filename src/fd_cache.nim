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
## * acquire - create or get existing file stream from cache.
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
import nimutils/file

# ----------------------------------------------------------------------------

proc getOpenLimit(): int =
  var limit: RLimit
  let success = getrlimit(RLIMIT_NOFILE, limit)
  if success != 0:
    raise newException(OSError, "Could not determine open file limit")
  return limit.rlim_cur

proc openFileStream(path: string, mode = fmRead): FileStream =
  var stream = newFileStream(path, mode = mode)
  if stream == nil:
    raise newException(OSError, path & ": cannot open for FD cache")
  return stream

# ----------------------------------------------------------------------------

type FDStream = ref object
    path:     string
    stream:   FileStream
    mode:     FileMode
    refCount: int

proc newStream(path: string, mode = fmRead): FDStream =
  var path = path.resolvePath()
  return FDStream(
    path:     path,
    stream:   openFileStream(path, mode = mode),
    mode:     mode,
    refCount: 0,
  )

proc acquireStream(self: FDStream, seek = 0): FileStream =
  if seek >= 0:
    self.stream.setPosition(seek)
  self.refCount += 1
  result = self.stream

proc releaseStream(self: FDStream) =
  self.refCount -= 1
  if self.refCount < 0:
    raise newException(ValueError, self.path & ": FD was released more times than acquired")

proc closeStream(self: FDStream) =
  self.stream.close()

proc isUsed(self: FDStream): bool =
  return self.refCount > 0

# ----------------------------------------------------------------------------

type FDCache = ref object
    size:     int
    byPath:   OrderedTable[string, FDStream]
    byStream: Table[FileStream, string]

proc `[]`(self: FDCache, path: string): FDStream =
  var path = path.resolvePath()
  if path notin self.byPath:
    raise newException(KeyError, path & ": not in FD cache")
  return self.byPath[path]

proc `[]`(self: FDCache, fs: FileStream): FDStream =
  if fs notin self.byStream:
    raise newException(KeyError, "file stream not in FD cache")
  let path = self.byStream[fs]
  return self[path]

proc `[]=`(self: FDCache, path: string, stream: FDStream) =
  var path = path.resolvePath()
  self.byPath[path] = stream
  self.byStream[stream.stream] = path

proc contains(self: FDCache, path: string): bool =
  return path.resolvePath() in self.byPath

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
    raise newException(OSError, stream.path & ": is still being used and cannot be evicted from FD cache.")
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
  self.maybeEvictLRUStreams(n = 0)

proc acquireFileStream(self:  FDCache,
                       path:  string,
                       seek   = 0,
                       mode   = fmRead,
                       strict = false,
                       ):     FileStream =
  self.maybeEvictLRUStreams(n = 1)
  var stream: FDStream

  if path in self and self[path].mode == mode:
    stream = self[path]
    # re-add to maintain LRU order
    self.del(stream)

  elif path in self:
    # requested mode doesnt match mode in cache
    # so close existing FD and create new one
    self.evictStream(self[path])

  if stream == nil:
    try:
      stream = newStream(path, mode = mode)
    except:
      if strict:
        raise
      return nil

  self[path] = stream
  result = stream.acquireStream(seek = seek)

proc releaseFileStream(self: FDCache, fs: FileStream) =
  if fs != nil:
    let stream = self[fs]
    stream.releaseStream()
    stream.stream.setPosition(0)

template withFileStream(self:   FDCache,
                        path:   string,
                        mode:   FileMode,
                        strict: bool,
                        code:   untyped) =
  var stream {.inject.}: FileStream
  try:
    stream = self.acquireFileStream(path, 0, mode, strict)
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

proc acquireFileStream*(path:  string,
                        seek   = 0,
                        strict = false,
                        mode   = fmRead,
                        ):     FileStream =
  return fdCache.acquireFileStream(path   = path,
                                 seek   = seek,
                                 strict = strict,
                                 mode   = mode)

proc releaseFileStream*(fs: FileStream) =
  fdCache.releaseFileStream(fs)

proc closeFileStream*(fs: FileStream) =
  fdCache.closeFileStream(fs)

proc closeFileStream*(path: string) =
  fdCache.closeFileStream(path)

template withFileStream*(path: string,
                         mode: FileMode,
                         strict: bool,
                         code: untyped) =
  fdCache.withFileStream(path, mode, strict):
    code
