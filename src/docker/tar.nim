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
  posix,
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
proc gzoffset(file: GzFile): int64 {.importc: "gzoffset".}
proc gzflush(file: GzFile, flush: cint): cint {.importc: "gzflush".}
{.pop.}

type
  SkippedFile*       = tuple[path: string, size: int64, hash: string]
  TarSizeLimitError* = object of CatchableError

## ---------------------------------------------------------------------------
## Tar format constants

const
  tarBlock       = 512
  tarNameLen     = 100
  tarLinkNameLen = 100
  tarPrefixLen   = 155
  tarChunkSize   = 65536
  flushInterval  = 1024 * 1024  ## 1 MiB of uncompressed data between size checks

## ---------------------------------------------------------------------------
## Internal helpers

proc toOctal*(n: int64, width: int): string =
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
  let
    zeros   = newString(n)
    written = gzwrite(gz, unsafeAddr zeros[0], cuint(n))
  if written != cint(n):
    var errnum: cint
    let msg = $gzerror(gz, addr errnum)
    raise newException(IOError, "gzwrite (zeros) failed: " & msg)

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
  ## Search limit is tarPrefixLen: any '/' at a higher index would produce a
  ## prefix longer than the 155-byte prefix field, which is invalid.
  if name.len > tarNameLen:
    var splitAt = -1
    let maxSearch = min(name.high - 1, tarPrefixLen)
    for i in countdown(maxSearch, 0):
      if name[i] == '/' and (name.len - i - 1) < tarNameLen:
        splitAt = i
        break
    if splitAt > 0:
      prefix = name[0 ..< splitAt]
      name   = name[splitAt + 1 .. ^1]
    ## If no valid ustar split exists, a GNU LongLink preamble will have been
    ## written by the caller; the name here is truncated to 100 chars and
    ## extractors use the preamble for the full name.

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

  ## Mtime (136..147): 11-digit octal + space; clamp pre-1970 times to 0.
  let mtimeStr = toOctal(max(0, mtime), 11)
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

proc matchOneChar(
    path:    string,
    pattern: string,
    si, pi:  int,
): tuple[matched: bool, newPi: int] =
  ## Match path[si] against the pattern element starting at pi.
  ## Returns (matched, newPi). Does not handle '*' -- caller manages wildcards.
  if si >= path.len or pi >= pattern.len:
    return (false, pi)
  case pattern[pi]
  of '?':
    if path[si] == '/':
      return (false, pi)
    return (true, pi + 1)
  of '[':
    var p = pi + 1
    let negate = p < pattern.len and (pattern[p] == '!' or pattern[p] == '^')
    if negate:
      inc p
    var classMatched = false
    var first = true
    while p < pattern.len and (first or pattern[p] != ']'):
      first = false
      if pattern[p] == '\\' and p + 1 < pattern.len:
        inc p
        if path[si] == pattern[p]:
          classMatched = true
        inc p
      elif p + 2 < pattern.len and pattern[p + 1] == '-' and pattern[p + 2] != ']':
        if path[si] >= pattern[p] and path[si] <= pattern[p + 2]:
          classMatched = true
        p += 3
      else:
        if path[si] == pattern[p]:
          classMatched = true
        inc p
    if p >= pattern.len:
      return (false, pi)  ## unterminated '[': no match
    inc p  ## skip ']'
    let classHit = if negate: not classMatched else: classMatched
    if path[si] == '/' or not classHit:
      return (false, pi)
    return (true, p)
  of '\\':
    if pi + 1 < pattern.len and path[si] == pattern[pi + 1]:
      return (true, pi + 2)
    return (false, pi)
  else:
    if path[si] == pattern[pi]:
      return (true, pi + 1)
    return (false, pi)

proc globMatch*(path, pattern: string): bool =
  ## Match path against a glob pattern.
  ## * matches any run of non-separator characters.
  ## ? matches any single non-separator character.
  ## ** matches any run of characters including path separators.
  ## [abc], [a-z], [!a-z] match character classes (/ never matches inside []).
  ## \x matches the literal character x.
  ##
  ## Uses an iterative anchor-stack approach: one saved (si, pi) entry per
  ## '**' encountered, O(k) space where k = number of '**' segments.
  type DStarAnchor = tuple[pi: int, si: int, hadSlash: bool]
  var
    si     = 0
    pi     = 0
    starPi = -1
    starSi = -1
    dstars: seq[DStarAnchor]

  while true:
    ## Consume wildcards at current pattern position.
    if pi < pattern.len and pattern[pi] == '*':
      if pi + 1 < pattern.len and pattern[pi + 1] == '*':
        ## Double star: save anchor and skip past '**[/]'.
        var dpi = pi + 2
        ## Consume the '/' after '**' if present.  When a slash was
        ## consumed the remaining sub-pattern must start on a path-
        ## component boundary (e.g. '**/.foo' must not match 'bar.foo').
        ## Without a slash (e.g. '**file') any position is valid.
        let hadSlash = dpi < pattern.len and pattern[dpi] == '/'
        if hadSlash:
          inc dpi
        if dpi >= pattern.len:
          return true  ## '**' at end of pattern matches everything remaining
        dstars.add((pi: dpi, si: si, hadSlash: hadSlash))
        pi = dpi
        starPi = -1
        starSi = -1
      else:
        ## Single star: save anchor and skip past '*'.
        starPi = pi + 1
        starSi = si
        inc pi
      continue

    ## Try to match one path character against the current pattern element.
    if si < path.len:
      let (matched, newPi) = matchOneChar(path, pattern, si, pi)
      if matched:
        pi = newPi
        inc si
        continue

    ## Check whether both pattern and path are exhausted.
    ## Trailing lone '*'s (not '**') are allowed to match empty.
    block checkComplete:
      var pp = pi
      while pp < pattern.len and pattern[pp] == '*' and
            (pp + 1 >= pattern.len or pattern[pp + 1] != '*'):
        inc pp
      if pp == pattern.len and si == path.len:
        return true

    ## Mismatch: backtrack.
    ## 1. Single-star anchor: advance one non-'/' path character and retry.
    if starPi >= 0 and starSi < path.len and path[starSi] != '/':
      inc starSi
      si = starSi
      pi = starPi
      continue

    ## 2. Double-star stack: advance the most-recent anchor to the next
    ##    valid path position and retry.  For hadSlash anchors only
    ##    component boundaries (si == 0 or path[si-1] == '/') are valid.
    block tryDstar:
      while dstars.len > 0:
        inc dstars[^1].si
        if dstars[^1].si > path.len:
          dstars.setLen(dstars.len - 1)
          starPi = -1
          starSi = -1
          continue
        if dstars[^1].hadSlash and
           dstars[^1].si > 0 and
           path[dstars[^1].si - 1] != '/':
          continue  ## not a component boundary; try next position
        si = dstars[^1].si
        pi = dstars[^1].pi
        starPi = -1
        starSi = -1
        break tryDstar
      return false

proc isValidPattern*(pattern: string): bool =
  ## Returns true if pattern is a syntactically valid glob pattern.
  ## Mirrors the two error cases in Go's filepath.Match (ErrBadPattern):
  ##   - unclosed '[' character class
  ##   - trailing '\' escape at end of pattern
  ## Leading '!' and trailing '/' are stripped before validation.
  let p = (if pattern.startsWith('!'): pattern[1 .. ^1] else: pattern).strip(chars = {'/'})
  var i = 0
  while i < p.len:
    case p[i]
    of '[':
      inc i
      if i < p.len and p[i] in {'!', '^'}:
        inc i
      var
        closed = false
        first  = true
      while i < p.len:
        if not first and p[i] == ']':
          closed = true
          inc i
          break
        first = false
        if p[i] == '\\':
          inc i
          if i >= p.len:
            return false
        inc i
      if not closed:
        return false
    of '\\':
      inc i
      if i >= p.len:
        return false
      inc i
    else:
      inc i
  return true

proc isExcluded*(relPath: string, patterns: seq[string]): bool =
  ## Returns true if relPath should be excluded given the ordered pattern list.
  ## Implements the same semantics as moby's patternmatcher.MatchesOrParentMatches
  ## (github.com/moby/patternmatcher). Rules:
  ## - Patterns are processed in order; the last match wins.
  ## - A leading '!' negates the pattern (re-includes a previously excluded path).
  ## - Trailing '/' is stripped before matching (it only signals directory intent).
  ## - All patterns -- with or without '/' -- are matched against the FULL
  ##   relative path. '*' never crosses '/'. So '*.log' only excludes root-level
  ##   '*.log' files, not 'subdir/foo.log'.
  ## - A path also matches if any of its ancestor directories matches the pattern
  ##   via a FULL-PATH match (e.g. pattern 'logs' excludes 'logs/debug.log'
  ##   because ancestor 'logs' == 'logs', but does NOT exclude 'a/logs/debug.log'
  ##   because ancestor 'a/logs' != 'logs').
  let norm = relPath.replace('\\', '/')
  result = false
  for pat in patterns:
    let
      negate   = pat.startsWith('!')
      p        = (if negate: pat[1 .. ^1] else: pat).strip(chars = {'/'})
    if p.len == 0:
      continue
    var matched = globMatch(norm, p)
    if not matched:
      var slash = norm.find('/')
      while slash > 0:
        let ancestor = norm[0 ..< slash]
        if globMatch(ancestor, p):
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
  ## `norm` when:
  ##   - it has no '/' and glob-matches norm itself (meaning norm would be
  ##     re-included, so its children must be visited too), or
  ##   - it contains '**' (can cross directory boundaries), or
  ##   - it is a slash pattern whose directory prefix at the same depth as
  ##     `norm` glob-matches `norm` (e.g. `!logs_*/f` reaches inside
  ##     `logs_app/`).
  for pat in patterns:
    if not pat.startsWith('!'):
      continue
    let p = pat[1 .. ^1].strip(chars = {'/'})
    if p.len == 0:
      continue
    if '/' notin p:
      ## A no-slash negation can re-include files inside norm/ only
      ## when the pattern matches norm itself -- all descendants would
      ## then be re-included via the ancestor check in isExcluded.
      if globMatch(norm, p):
        return true
    elif "**" in p:
      return true
    ## Check if the prefix of `p` at the same directory depth as `norm`
    ## glob-matches `norm`.  This handles wildcarded slash patterns such as
    ## `!logs_*/important.log` that can re-include files inside `logs_app/`.
    let normDepth = norm.count('/') + 1
    var
      slashes = 0
      idx     = 0
    while idx < p.len:
      if p[idx] == '/':
        inc slashes
        if slashes == normDepth:
          break
      inc idx
    if slashes == normDepth:
      let prefix = p[0 ..< idx]
      if globMatch(norm, prefix):
        return true
  return false

proc checkSizeThreshold(gz: GzFile, sizeThreshold: int64) =
  ## Unconditionally flush gzip output and raise TarSizeLimitError if the
  ## compressed output exceeds sizeThreshold.  Used at end of archive.
  if sizeThreshold <= 0:
    return
  discard gzflush(gz, 2)  ## Z_SYNC_FLUSH: flush to fd so gzoffset is accurate
  if gzoffset(gz) > sizeThreshold:
    raise newException(
      TarSizeLimitError,
      "archive exceeded size_threshold of " & $sizeThreshold & " bytes",
    )

proc maybeCheckSize(
    gz:            GzFile,
    sizeThreshold: int64,
    pending:       var int64,
) =
  ## Flush and check compressed size only when enough uncompressed data has
  ## accumulated since the last flush (flushInterval bytes).  Batching flushes
  ## avoids Z_SYNC_FLUSH overhead on every small entry (dirs, symlinks).
  if sizeThreshold <= 0 or pending < flushInterval:
    return
  discard gzflush(gz, 2)  ## Z_SYNC_FLUSH
  if gzoffset(gz) > sizeThreshold:
    raise newException(
      TarSizeLimitError,
      "archive exceeded size_threshold of " & $sizeThreshold & " bytes",
    )
  pending = 0

proc needsLongLink(relPath: string, isDir: bool): bool =
  ## Returns true when relPath cannot be stored in ustar prefix+name fields.
  var name = relPath.replace('\\', '/')
  if isDir and not name.endsWith('/'):
    name.add('/')
  if name.len <= tarNameLen:
    return false
  let maxSearch = min(name.high - 1, tarPrefixLen)
  for i in countdown(maxSearch, 0):
    if name[i] == '/' and (name.len - i - 1) < tarNameLen:
      return false
  return true

proc writeLongLinkPreamble(gz: GzFile, data: string, typeFlag: char): int64 =
  ## Emit a GNU tar ././@LongLink preamble block.
  ## typeFlag 'L' = long path name, 'K' = long symlink target.
  ## Returns the number of uncompressed bytes written.
  let
    payload = data & "\0"
    pad     = (tarBlock - (payload.len mod tarBlock)) mod tarBlock
    hdr     = buildTarHeader(
      relPath  = "././@LongLink",
      size     = int64(payload.len),
      isDir    = false,
      mtime    = 0,
      typeFlag = typeFlag,
    )
  gz.gzWriteAll(hdr)
  gz.gzWriteAll(payload)
  if pad > 0:
    gzWriteZeros(gz, pad)
  return int64(tarBlock + payload.len + pad)

proc writeLongLinkEntry(gz: GzFile, fullPath: string): int64 =
  ## Emit a GNU tar ././@LongLink 'L' preamble for a path name that exceeds ustar limits.
  return gz.writeLongLinkPreamble(fullPath, 'L')

proc writeLongLinkTargetEntry(gz: GzFile, target: string): int64 =
  ## Emit a GNU tar ././@LongLink 'K' preamble for a symlink target that exceeds 100 bytes.
  return gz.writeLongLinkPreamble(target, 'K')

## ---------------------------------------------------------------------------
## Directory walk

proc addDirToTar(
    gz:            GzFile,
    baseDir:       string,
    relDir:        string,
    patterns:      seq[string],
    maxFileSize:   int64,
    sizeThreshold: int64,
    skippedFiles:  var seq[SkippedFile],
    pending:       var int64,
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
        var entryBytes = int64(tarBlock)
        if needsLongLink(relPath = norm, isDir = true):
          entryBytes += gz.writeLongLinkEntry(norm & "/")
        gz.gzWriteAll(buildTarHeader(
          relPath = norm,
          size    = 0,
          isDir   = true,
          mtime   = mtime,
        ))
        pending += entryBytes
        maybeCheckSize(gz, sizeThreshold, pending)
      ## Only recurse into an excluded directory when a negation pattern
      ## could re-include files inside it (e.g. "logs/" with "!logs/*.log").
      ## Pruning here avoids walking .git, node_modules, etc. unnecessarily.
      if not excluded or hasNegationForDir(norm, patterns):
        addDirToTar(gz, baseDir, rel, patterns, maxFileSize, sizeThreshold, skippedFiles, pending)

    of pcFile:
      if isExcluded(norm, patterns):
        trace("docker: context upload: excluding " & norm)
        continue
      var st: Stat
      if stat(full, st) != 0 or not S_ISREG(st.st_mode):
        trace("docker: context upload: skipping non-regular file " & norm)
        continue
      let
        size  = int64(st.st_size)
        mtime = when defined(macosx): int64(st.st_mtimespec.tv_sec)
                else:                 int64(st.st_mtim.tv_sec)
        fss   = newFileStringStream(full)
      if maxFileSize > 0 and size > maxFileSize:
        let hash = fss.sha256Hex()
        trace("docker: context upload: skipping large file " & norm &
              " (sha256:" & hash & " size:" & $size &
              " bytes > max_file_size:" & $maxFileSize & " bytes)")
        skippedFiles.add((path: norm, size: size, hash: hash))
        continue
      var entryBytes = int64(tarBlock)
      if needsLongLink(relPath = norm, isDir = false):
        entryBytes += gz.writeLongLinkEntry(norm)
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
        if written != size:
          raise newException(
            IOError,
            "file size changed during context upload (context is mutating): " &
            norm & " (expected " & $size & " bytes, got " & $written & ")",
          )
        let pad = (tarBlock - int(size mod tarBlock)) mod tarBlock
        if pad > 0:
          gzWriteZeros(gz, pad)
        entryBytes += size + int64(pad)
      finally:
        fh.close()
      pending += entryBytes
      maybeCheckSize(gz, sizeThreshold, pending)

    of pcLinkToFile, pcLinkToDir:
      if isExcluded(norm, patterns):
        trace("docker: context upload: excluding symlink " & norm)
        continue
      let
        target = expandSymlink(full)
        mtime  = getFileInfo(full, followSymlink = false).lastWriteTime.toUnix()
      trace("docker: context upload: adding symlink " & norm & " -> " & target)
      var entryBytes = int64(tarBlock)
      if needsLongLink(relPath = norm, isDir = false):
        entryBytes += gz.writeLongLinkEntry(norm)
      if target.len > tarLinkNameLen:
        entryBytes += gz.writeLongLinkTargetEntry(target)
      gz.gzWriteAll(buildTarHeader(
        relPath    = norm,
        size       = 0,
        isDir      = false,
        mtime      = mtime,
        linkTarget = target,
      ))
      pending += entryBytes
      maybeCheckSize(gz, sizeThreshold, pending)

## ---------------------------------------------------------------------------
## Public API

proc writeTarGz*(
    outPath:       string,
    contextPath:   string,
    patterns:      seq[string],
    maxFileSize:   int64 = 0,
    sizeThreshold: int64 = 0,
): seq[SkippedFile] =
  ## Write a .tar.gz of contextPath to outPath.
  ## Files and directories whose path relative to contextPath matches any
  ## entry in patterns are excluded from the archive.
  ## Individual files larger than maxFileSize bytes are skipped (0 = no limit).
  ## If sizeThreshold > 0, raises TarSizeLimitError as soon as the compressed
  ## output exceeds the threshold, avoiding writing the full archive.
  ## Returns the list of files that were skipped due to maxFileSize.
  var validPatterns: seq[string]
  for p in patterns:
    if isValidPattern(p):
      validPatterns.add(p)
    else:
      raise newException(ValueError, "invalid dockerignore pattern: " & p)
  let gz = gzopen(outPath.cstring, "wb")
  if gz == nil:
    raise newException(IOError, "could not open " & outPath & " for gzip writing")
  var
    ok      = false
    pending = int64(0)
  try:
    addDirToTar(gz, contextPath, "", validPatterns, maxFileSize, sizeThreshold, result, pending)
    gzWriteZeros(gz, tarBlock * 2)  ## POSIX end-of-archive: two zero blocks
    gz.checkSizeThreshold(sizeThreshold)
    ok = true
  finally:
    let rc = gzclose(gz)
    if ok and rc != 0:
      raise newException(IOError, "gzclose failed: rc=" & $rc)
  ## Final size check after gzclose flushes all buffered data.
  ## The incremental check in addDirToTar catches large archives early,
  ## but gzip buffering can delay flushing for small archives.
  if sizeThreshold > 0 and getFileSize(outPath) > sizeThreshold:
    removeFile(outPath)
    raise newException(
      TarSizeLimitError,
      "archive exceeded size_threshold of " & $sizeThreshold & " bytes",
    )
