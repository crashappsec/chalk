##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Streaming .tar.gz writer using zlib's gzFile API.
## Files are written one at a time directly to the compressed output;
## no complete in-memory copy of the archive is ever held.

import std/[
  os,
  strutils,
  times,
]
import ".."/[
  types,
]

## ---------------------------------------------------------------------------
## zlib FFI

type GzFile = pointer

{.push header: "<zlib.h>".}
proc gzopen(path: cstring, mode: cstring): GzFile {.importc: "gzopen".}
proc gzwrite(file: GzFile, buf: pointer, len: cuint): cint {.importc: "gzwrite".}
proc gzclose(file: GzFile): cint {.importc: "gzclose".}
proc gzerror(file: GzFile, errnum: ptr cint): cstring {.importc: "gzerror".}
{.pop.}

## ---------------------------------------------------------------------------
## Tar format constants

const
  tarBlock      = 512
  tarNameLen    = 100
  tarPrefixLen  = 155
  tarChunkSize  = 65536

## ---------------------------------------------------------------------------
## Internal helpers

proc toOctal(n: int64, width: int): string =
  result = newString(width)
  var v = n
  for i in countdown(width - 1, 0):
    result[i] = char(ord('0') + int(v and 7))
    v = v shr 3

proc gzWriteAll(gz: GzFile, data: string) =
  if data.len == 0:
    return
  let written = gzwrite(gz, unsafeAddr data[0], cuint(data.len))
  if written != cint(data.len):
    var errnum: cint
    let msg = $gzerror(gz, addr errnum)
    raise newException(IOError, "gzwrite failed: " & msg)

proc gzWriteZeros(gz: GzFile, n: int) =
  if n <= 0:
    return
  let zeros = newString(n)
  discard gzwrite(gz, unsafeAddr zeros[0], cuint(n))

proc buildTarHeader(
    relPath: string,
    size:    int64,
    isDir:   bool,
    mtime:   int64,
): string =
  result = newString(tarBlock)  ## zero-filled

  var name   = relPath.replace('\\', '/')
  var prefix = ""
  if isDir and not name.endsWith('/'):
    name.add('/')

  ## Split long paths using ustar prefix field (prefix/name, each null-terminated).
  if name.len > tarNameLen:
    var splitAt = -1
    let maxSearch = min(name.high - 1, tarNameLen + tarPrefixLen - 1)
    for i in countdown(maxSearch, 0):
      if name[i] == '/' and (name.len - i - 1) < tarNameLen:
        splitAt = i
        break
    if splitAt > 0:
      prefix = name[0 ..< splitAt]
      name   = name[splitAt + 1 .. ^1]
    ## If still too long, name is truncated; rare for real contexts.

  ## Name field (0..99)
  for i in 0 ..< min(name.len, tarNameLen):
    result[i] = name[i]

  ## Mode (100..107): "0000755\0" for dirs, "0000644\0" for files
  let modeStr = if isDir: "0000755\0" else: "0000644\0"
  for i in 0 ..< 8:
    result[100 + i] = modeStr[i]

  ## UID, GID (108..115, 116..123): "0000000\0"
  for base in [108, 116]:
    for i in 0 ..< 7:
      result[base + i] = '0'
    result[base + 7] = '\0'

  ## File size (124..135): 11-digit octal + space
  let sizeStr = toOctal(size, 11)
  for i in 0 ..< 11:
    result[124 + i] = sizeStr[i]
  result[135] = ' '

  ## Mtime (136..147): 11-digit octal + space
  let mtimeStr = toOctal(mtime, 11)
  for i in 0 ..< 11:
    result[136 + i] = mtimeStr[i]
  result[147] = ' '

  ## Checksum placeholder: 8 spaces (148..155) - filled in below
  for i in 0 ..< 8:
    result[148 + i] = ' '

  ## Type flag (156): '5' = directory, '0' = regular file
  result[156] = if isDir: '5' else: '0'

  ## UStar magic (257..262) and version (263..264)
  result[257] = 'u'
  result[258] = 's'
  result[259] = 't'
  result[260] = 'a'
  result[261] = 'r'
  result[262] = '\0'
  result[263] = '0'
  result[264] = '0'

  ## Prefix field (345..499)
  for i in 0 ..< min(prefix.len, tarPrefixLen):
    result[345 + i] = prefix[i]

  ## Checksum: sum of all 512 bytes with the checksum field set to spaces
  var sum = 0
  for c in result:
    sum += int(c)

  ## Write 6 octal digits + null + space into checksum field
  let csStr = toOctal(int64(sum), 6) & "\0 "
  for i in 0 ..< 8:
    result[148 + i] = csStr[i]

## ---------------------------------------------------------------------------
## Glob pattern matching

proc globMatch*(path, pattern: string): bool =
  ## Match path against a glob pattern.
  ## * matches any run of non-separator characters.
  ## ? matches any single non-separator character.
  ## ** matches any run of characters including path separators.
  var pi, si = 0
  while pi < pattern.len and si < path.len:
    if pattern[pi] == '*':
      let doubleStar = pi + 1 < pattern.len and pattern[pi + 1] == '*'
      if doubleStar:
        pi += 2
        if pi < pattern.len and pattern[pi] == '/':
          inc pi
        if pi >= pattern.len:
          return true
        while si <= path.len:
          if globMatch(path[si .. ^1], pattern[pi .. ^1]):
            return true
          inc si
        return false
      else:
        inc pi
        while si < path.len and path[si] != '/':
          if globMatch(path[si .. ^1], pattern[pi .. ^1]):
            return true
          inc si
        return globMatch(path[si .. ^1], pattern[pi .. ^1])
    elif pattern[pi] == '?' and path[si] != '/':
      inc pi
      inc si
    elif pattern[pi] == path[si]:
      inc pi
      inc si
    else:
      return false
  while pi < pattern.len and pattern[pi] == '*':
    inc pi
  return pi == pattern.len and si == path.len

proc isExcluded*(relPath: string, patterns: seq[string]): bool =
  ## Returns true if relPath should be excluded given the ordered pattern list.
  ## Patterns are processed in order; the last match wins.
  ## A leading '!' negates the pattern (re-includes a previously excluded path).
  ## Patterns without '/' are matched against each path component individually.
  ## Patterns with '/' are matched against the full relative path.
  let norm = relPath.replace('\\', '/')
  result = false
  for pat in patterns:
    let
      negate = pat.startsWith('!')
      p      = (if negate: pat[1 .. ^1] else: pat).strip(chars = {'/'})
    if p.len == 0:
      continue
    let matches =
      if '/' notin p:
        block:
          var found = false
          for component in norm.split('/'):
            if component.len > 0 and globMatch(component, p):
              found = true
              break
          found
      else:
        globMatch(norm, p)
    if matches:
      result = not negate

## ---------------------------------------------------------------------------
## Directory walk

proc addDirToTar(
    gz:       GzFile,
    baseDir:  string,
    relDir:   string,
    patterns: seq[string],
) =
  for kind, entry in walkDir(baseDir / relDir, relative = true):
    let
      rel  = (if relDir == "": entry else: relDir / entry)
      norm = rel.replace('\\', '/')
      full = baseDir / rel

    case kind:
    of pcDir:
      if not isExcluded(norm, patterns):
        let mtime = full.getLastModificationTime().toUnix()
        gz.gzWriteAll(buildTarHeader(norm, 0, isDir = true, mtime))
      ## Always recurse so negation patterns can re-include files inside
      ## an excluded directory (e.g. "logs/" with "!logs/*.log").
      addDirToTar(gz, baseDir, rel, patterns)

    of pcFile:
      if isExcluded(norm, patterns):
        trace("docker: context upload: excluding " & norm)
        continue
      let
        size  = full.getFileSize()
        mtime = full.getLastModificationTime().toUnix()
      gz.gzWriteAll(buildTarHeader(norm, size, isDir = false, mtime))
      let fh = open(full, fmRead)
      try:
        var written: int64
        var chunk = newString(tarChunkSize)
        while true:
          let n = fh.readBuffer(addr chunk[0], tarChunkSize)
          if n <= 0:
            break
          gz.gzWriteAll(chunk[0 ..< n])
          written += int64(n)
        let pad = (tarBlock - int(written mod tarBlock)) mod tarBlock
        if pad > 0:
          gzWriteZeros(gz, pad)
      finally:
        fh.close()

    else:
      discard  ## skip symlinks and other special files

## ---------------------------------------------------------------------------
## Public API

proc writeTarGz*(
    outPath:     string,
    contextPath: string,
    patterns:    seq[string],
) =
  ## Write a .tar.gz of contextPath to outPath.
  ## Files and directories whose path relative to contextPath matches any
  ## entry in patterns are excluded from the archive.
  let gz = gzopen(outPath.cstring, "wb")
  if gz == nil:
    raise newException(IOError, "could not open " & outPath & " for gzip writing")
  try:
    addDirToTar(gz, contextPath, "", patterns)
    gzWriteZeros(gz, tarBlock * 2)  ## POSIX end-of-archive: two zero blocks
  finally:
    discard gzclose(gz)
