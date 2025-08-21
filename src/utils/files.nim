##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  posix,
  tempfiles,
  unicode,
]
import pkg/[
  nimutils/logging,
  nimutils/managedtmp,
]
import ".."/[
  con4mwrap,
  types,
]
import "."/[
  fd_cache,
  file_string_stream,
  strings,
  times, # TODO remove
]

export fd_cache
export file_string_stream
export managedtmp
export os
export tempfiles

const
  tmpFilePrefix*      = "chalk-"
  tmpFileSuffix*      = "-file.tmp"

proc replaceFileContents*(fsRef: string, contents: string): bool =
  if fsRef == "":
    error("replaceFileContents() called on an artifact that " &
          "isn't associated with a file.")
    return false

  # Need to close in order to successfully replace.
  closeFileStream(fsRef)

  result = true

  var
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)
    info: Stat

  try:
    ctx.write(contents)
  finally:
    if ctx != nil:
      try:
        ctx.close()
        # If we can successfully stat the file, we will try to
        # re-apply the same mode bits via chmod after the move.
        let statResult = stat(cstring(fsRef), info)
        moveFile(fsRef, path & ".old")
        moveFile(path, fsRef)
        if statResult == 0:
          discard chmod(cstring(fsRef), info.st_mode)
      except:
        error("file: " & getCurrentExceptionMsg())
        removeFile(path)
        if not fileExists(fsRef):
          # We might have managed to move it but not copy the new guy in.
          try:
            moveFile(path & ".old", fsRef)
          except:
            error(fsRef & " was moved before copying in the new " &
              "file, but the op failed, and the file could not be replaced. " &
              " It currently is in: " & path & ".old")
        else:
            error(fsRef & ": Could not write (no permission)")
        dumpExOnDebug()
        return false

proc canOpenFile*(path: string, mode: FileMode = FileMode.fmRead): bool =
  var canOpen = false
  try:
    let stream = openFileStream(path, mode = mode)
    if stream != nil:
      canOpen = true
      stream.close()
  except:
    dumpExOnDebug()
    error(getCurrentExceptionMsg())
  finally:
    if mode != FileMode.fmRead:
      try:
        discard tryRemoveFile(path)
      except:
        discard
  return canOpen

proc seemsToBeUtf8*(stream: FileStream): bool =
  try:
    let s = stream.peekStr(256)
    # The below call returns the position of the first bad byte, or -1
    # if it *is* valid.
    if s.validateUtf8() != -1:
      return false
    else:
      return true
  except:
    return false

proc reportTmpFileExitState(files, dirs, errs: seq[string]) =
  for err in errs:
    error(err)

  if attrGet[bool]("chalk_debug") and len(dirs) + len(files) != 0:
    error("Due to --debug flag, skipping cleanup; moving the " &
          "following to ./chalk-tmp:")
    for item in files & dirs:
      error(item)

  # TODO move elsewhere as timing doesnt belong in tmp module
  reportTotalTime()

proc setupManagedTemp*() =
  let customTmpDirOpt = attrGetOpt[string]("default_tmp_dir")

  if customTmpDirOpt.isSome() and not existsEnv("TMPDIR"):
    putEnv("TMPDIR", customTmpDirOpt.get())

  # temp folder needs to exist in order to successfully create
  # tmp files otherwise nim's createTempFile throws segfault
  # when TMPDIR does not exist
  if existsEnv("TMPDIR"):
    discard existsOrCreateDir(getEnv("TMPDIR"))

  if attrGet[bool]("chalk_debug"):
    let
      tmpPath = resolvePath("chalk-tmp")
      tmpCheck = resolvePath(".chalk-tmp-check")
    if canOpenFile(tmpCheck, mode = FileMode.fmWrite):
      info("Debug is on; temp files / dirs will be moved to " & tmpPath & ", not deleted.")
      setManagedTmpCopyLocation(tmpPath)
    else:
      warn("Debug is on however chalk is unable to move temp files to " & tmpPath)

  setManagedTmpExitCallback(reportTmpFileExitState)
  setDefaultTmpFilePrefix(tmpFilePrefix)
  setDefaultTmpFileSuffix(tmpFileSuffix)

proc getRelativePathBetween*(fromPath: string, toPath: string) : string =
  ## Given the `fromPath`, usually the project root, return the relative
  ## path of the file's `toPath`. Return nothing if its outside the project root,
  ## if `toPath` is an empty string or, if Dockerfile contents was passed via stdin.
  result = toPath.relativePath(fromPath)
  if result.startsWith("..") or result == "" or result == stdinIndicator:
    trace("File is ephemeral or not contained within VCS project")
    return ""

when defined(linux):
  iterator allFileMounts*(): string =
    withFileStream("/proc/mounts", mode = fmRead, strict = true):
      for l in stream.lines():
        if l == "":
          continue
        let parts = strutils.splitWhitespace(l)
        if len(parts) <= 2:
          continue
        let path = parts[1]
        if not path.startsWithAnyOf(systemIgnoreStartsWithPaths) and path.fileExists():
          yield path

else:
  iterator allFileMounts*(): string =
    discard

type AlreadyExists* = object of CatchableError

proc acquireExclusiveFile*(path: string, mode = S_IRUSR or S_IWUSR, close = true): cint =
  let fd = open(
    cstring(path),
    O_EXCL or O_CREAT or O_WRONLY,
    mode,
  )
  if fd < 0:
    if errno == EEXIST:
      raise newException(AlreadyExists, path)
    else:
      raiseOSError(osLastError(), "could not create exclusive file")
  if close:
    discard close(fd)
    return 0
  return fd

proc getOrWriteExclusiveFile*(path: string, data: string, mode = S_IRUSR or S_IWUSR): string =
  try:
    let fd = acquireExclusiveFile(path, mode = mode, close = false)
    try:
      if write(fd, cstring(data), len(data)) < 0:
        raiseOSError(osLastError(), "could not write to exclusive file")
      return data
    finally:
      discard close(fd)
  except AlreadyExists:
    return tryToLoadFile(path)
