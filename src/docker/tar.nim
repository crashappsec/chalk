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
  utils/files,
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

type
  SkippedFile* = tuple[path: string, size: int64, hash: string]

## ---------------------------------------------------------------------------
## Tar format constants

const
  tarBlock       = 512
  tarNameLen     = 100
  tarLinkNameLen = 100
  tarPrefixLen   = 155
  tarChunkSize   = 65536

## ---------------------------------------------------------------------------
## Internal helpers

proc toOctal(n: int64, width: int): string =
  result = newString(width)
  var v = n
  for i in countdown(width - 1, 0):
    result[i] = char(ord('0') + int(v and 7))
    v = v shr 3
  if v != 0:
    raise newException(
      ValueError,
      "value " & $n & " does not fit in " & $width & " octal digits",
    )

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
    relPath:    string,
    size:       int64,
    isDir:      bool,
    mtime:      int64,
    linkTarget: string = "",
    typeFlag:   char   = '\0',
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

  ## Mode (100..107): "0000755\0" for dirs, "0000777\0" for symlinks, "0000644\0" for files
  let modeStr =
    if isDir:              "0000755\0"
    elif linkTarget != "": "0000777\0"
    else:                  "0000644\0"
  for i in 0 ..< 8:
    result[100 + i] = modeStr[i]

  ## UID, GID (108..115, 116..123): "0000000\0"
  for base in [108, 116]:
    for i in 0 ..< 7:
      result[base + i] = '0'
    result[base + 7] = '\0'

  ## File size (124..135): 11-digit octal + space (0 for symlinks and dirs)
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

  ## Type flag (156): 'L' = GNU longname preamble, '5' = directory,
  ##                  '2' = symlink, '0' = regular file
  result[156] =
    if typeFlag != '\0':   typeFlag
    elif isDir:            '5'
    elif linkTarget != "": '2'
    else:                  '0'

  ## Linkname field (157..256): symlink target, null-terminated
  if linkTarget != "":
    for i in 0 ..< min(linkTarget.len, tarLinkNameLen):
      result[157 + i] = linkTarget[i]

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
  ## Matches Docker .dockerignore semantics:
  ## - Patterns are processed in order; the last match wins.
  ## - A leading '!' negates the pattern (re-includes a previously excluded path).
  ## - Trailing '/' is stripped before matching (it only signals directory intent).
  ## - The full relative path is matched against the cleaned pattern with globMatch.
  ## - A path also matches if any of its ancestor directories matches the pattern,
  ##   which is how "logs/" covers "logs/debug.log".
  let norm = relPath.replace('\\', '/')
  result = false
  for pat in patterns:
    let
      negate = pat.startsWith('!')
      p      = (if negate: pat[1 .. ^1] else: pat).strip(chars = {'/'})
    if p.len == 0:
      continue
    var matched = globMatch(norm, p)
    if not matched:
      var slash = norm.find('/')
      while slash > 0:
        if globMatch(norm[0 ..< slash], p):
          matched = true
          break
        slash = norm.find('/', slash + 1)
    if matched:
      result = not negate

proc hasNegationForDir*(norm: string, patterns: seq[string]): bool =
  ## Returns true if any negation pattern in `patterns` could re-include
  ## files inside the directory at `norm`, meaning recursion must not be pruned.
  ##
  ## Under Docker .dockerignore semantics a negation pattern can reach inside
  ## `norm` only when:
  ##   - it explicitly starts with `norm/` (targets files inside this dir), or
  ##   - it contains '**' (can cross directory boundaries).
  ## Patterns without a '/' cannot match across a directory boundary, so they
  ## cannot re-include files inside an excluded subdirectory.
  for pat in patterns:
    if not pat.startsWith('!'):
      continue
    let p = pat[1 .. ^1].strip(chars = {'/'})
    if p.len == 0:
      continue
    if p.startsWith(norm & "/"):
      return true
    if "**" in p:
      return true
  return false

proc needsLongLink(relPath: string, isDir: bool): bool =
  ## Returns true when relPath cannot be stored in ustar prefix+name fields.
  var name = relPath.replace('\\', '/')
  if isDir and not name.endsWith('/'):
    name.add('/')
  if name.len <= tarNameLen:
    return false
  let maxSearch = min(name.high - 1, tarNameLen + tarPrefixLen - 1)
  for i in countdown(maxSearch, 0):
    if name[i] == '/' and (name.len - i - 1) < tarNameLen:
      return false
  return true

proc writeLongLinkEntry(gz: GzFile, fullPath: string) =
  ## Emit a GNU tar ././@LongLink preamble for paths that exceed ustar limits.
  ## Readers use this entry's data block as the name for the entry that follows.
  let
    data = fullPath & "\0"
    hdr  = buildTarHeader(
      relPath  = "././@LongLink",
      size     = int64(data.len),
      isDir    = false,
      mtime    = 0,
      typeFlag = 'L',
    )
  gz.gzWriteAll(hdr)
  gz.gzWriteAll(data)
  let pad = (tarBlock - (data.len mod tarBlock)) mod tarBlock
  if pad > 0:
    gzWriteZeros(gz, pad)

## ---------------------------------------------------------------------------
## Directory walk

proc addDirToTar(
    gz:           GzFile,
    baseDir:      string,
    relDir:       string,
    patterns:     seq[string],
    maxFileSize:  int64,
    skippedFiles: var seq[SkippedFile],
) =
  for kind, entry in walkDir(baseDir / relDir, relative = true):
    let
      rel  = (if relDir == "": entry else: relDir / entry)
      norm = rel.replace('\\', '/')
      full = baseDir / rel

    case kind:
    of pcDir:
      let excluded = isExcluded(norm, patterns)
      if not excluded:
        let mtime = full.getLastModificationTime().toUnix()
        if needsLongLink(relPath = norm, isDir = true):
          gz.writeLongLinkEntry(norm & "/")
        gz.gzWriteAll(buildTarHeader(
          relPath = norm,
          size    = 0,
          isDir   = true,
          mtime   = mtime,
        ))
      ## Only recurse into an excluded directory when a negation pattern
      ## could re-include files inside it (e.g. "logs/" with "!logs/*.log").
      ## Pruning here avoids walking .git, node_modules, etc. unnecessarily.
      if not excluded or hasNegationForDir(norm, patterns):
        addDirToTar(gz, baseDir, rel, patterns, maxFileSize, skippedFiles)

    of pcFile:
      if isExcluded(norm, patterns):
        trace("docker: context upload: excluding " & norm)
        continue
      let
        fss   = newFileStringStream(full)
        size  = int64(len(fss))
        mtime = full.getLastModificationTime().toUnix()
      if maxFileSize > 0 and size > maxFileSize:
        let hash = fss.sha256Hex()
        trace("docker: context upload: skipping large file " & norm &
              " (sha256:" & hash & " size:" & $size &
              " bytes > max_file_size:" & $maxFileSize & " bytes)")
        skippedFiles.add((path: norm, size: size, hash: hash))
        continue
      if needsLongLink(relPath = norm, isDir = false):
        gz.writeLongLinkEntry(norm)
      gz.gzWriteAll(buildTarHeader(
        relPath = norm,
        size    = size,
        isDir   = false,
        mtime   = mtime,
      ))
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

    of pcLinkToFile, pcLinkToDir:
      if isExcluded(norm, patterns):
        trace("docker: context upload: excluding symlink " & norm)
        continue
      let
        target = expandSymlink(full)
        mtime  = full.getLastModificationTime().toUnix()
      trace("docker: context upload: adding symlink " & norm & " -> " & target)
      if needsLongLink(relPath = norm, isDir = false):
        gz.writeLongLinkEntry(norm)
      gz.gzWriteAll(buildTarHeader(
        relPath    = norm,
        size       = 0,
        isDir      = false,
        mtime      = mtime,
        linkTarget = target,
      ))

## ---------------------------------------------------------------------------
## Public API

proc writeTarGz*(
    outPath:     string,
    contextPath: string,
    patterns:    seq[string],
    maxFileSize: int64 = 0,
): seq[SkippedFile] =
  ## Write a .tar.gz of contextPath to outPath.
  ## Files and directories whose path relative to contextPath matches any
  ## entry in patterns are excluded from the archive.
  ## Individual files larger than maxFileSize bytes are skipped (0 = no limit).
  ## Returns the list of files that were skipped due to maxFileSize.
  let gz = gzopen(outPath.cstring, "wb")
  if gz == nil:
    raise newException(IOError, "could not open " & outPath & " for gzip writing")
  try:
    addDirToTar(gz, contextPath, "", patterns, maxFileSize, result)
    gzWriteZeros(gz, tarBlock * 2)  ## POSIX end-of-archive: two zero blocks
  finally:
    discard gzclose(gz)
