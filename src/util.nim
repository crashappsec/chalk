## This is for any common code for system stuff, such as executing code.
## :Author: John Viega
## :Copyright: 2023, Crash Override, Inc.

import  std/tempfiles, posix, posix_utils, config

proc replaceFileContents*(chalk: ChalkObj, contents: string): bool =
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
        let statResult = stat(cstring(chalk.fullpath), info)
        moveFile(chalk.fullPath, path & ".old")
        moveFile(path, chalk.fullpath)
        if statResult == 0:
          discard chmod(cstring(chalk.fullpath), info.st_mode)
      except:
        removeFile(path)
        if not fileExists(chalk.fullPath):
          # We might have managed to move it but not copy the new guy in.
          try:
            moveFile(path & ".old", chalk.fullPath)
          except:
            error(chalk.fullPath & " was moved before copying in the new " &
              "file, but the op failed, and the file could not be replaced. " &
              " It currently is in: " & path & ".old")
        else:
            error(chalk.fullPath & ": Could not write (no permission)")
        dumpExOnDebug()
        return false




const
  S_IFMT  = 0xf000
  S_IFREG = 0x8000
  S_IXUSR = 0x0040
  S_IXGRP = 0x0008
  S_IXOTH = 0x0001
  S_IXALL = S_IXUSR or S_IXGRP or S_IXOTH

template isFile*(info: Stat): bool =
  (info.st_mode and S_IFMT) == S_IFREG

template hasUserExeBit*(info: Stat): bool =
  (info.st_mode and S_IXUSR) != 0

template hasGroupExeBit*(info: Stat): bool =
  (info.st_mode and S_IXGRP) != 0

template hasOtherExeBit*(info: Stat): bool =
  (info.st_mode and S_IXOTH) != 0

template hasAnyExeBit*(info: Stat): bool =
  (info.st_mode and S_IXALL) != 0

proc isExecutable*(path: string): bool =
  try:
    let info = stat(path)

    if not info.isFile():
      return false

    if not info.hasAnyExeBit():
      return false

    let myeuid = geteuid()

    if myeuid == 0:
      return true

    if info.st_uid == myeuid:
      return info.hasUserExeBit()

    var groupinfo: array[0 .. 255, Gid]
    let numGroups = getgroups(255, addr groupinfo)

    if info.st_gid in groupinfo[0 ..< numGroups]:
      return info.hasGroupExeBit()

    return info.hasOtherExeBit()

  except:
    return false # Couldn't stat.

proc findAllExePaths*(cmdName:    string,
                      extraPaths: seq[string] = @[],
                       usePath                = true): seq[string] =
  ##
  ## The priority here is to the passed command name, but if and only
  ## if it is a path; we're assuming that they want to try to run
  ## something in a particular location.  Generally, we're disallowing
  ## this in config files, but it's here just in case.
  ##
  ## Our second priority is to the the extraPaths array, which is
  ## basically a programmer supplied PATH, in case the right place
  ## doesn't get picked up in our environment.
  ##
  ## If all else fails, we search the PATH environment variable.
  ##
  ## Note that we don't check for permissions problems (including
  ## not-executable), and we do not open the file, so there's the
  ## chance of the executable going away before we try to run it.
  ##
  ## The point is, the caller should eanticipate failure.
  let
    (mydir, me) = getMyAppPath().splitPath()
  var
    targetName  = cmdName
    allPaths    = extraPaths

  if usePath:
    allPaths &= getEnv("PATH").split(":")

  if '/' in cmdName:
    let tup    = resolvePath(cmdName).splitPath()
    targetName = tup.tail
    allPaths   = @[tup.head] & allPaths

  for path in allPaths:
    if me == targetName and path == mydir: continue # Don't ever find ourself.
    let potential = joinpath(path, targetName)
    if potential.isExecutable():
      result.add(potential)

proc findExePath*(cmdName:    string,
                  extraPaths: seq[string] = @[],
                  usePath = true): Option[string] =
  let foundExes = findAllExePaths(cmdName, extraPaths, usePath)

  if foundExes.len() == 0:
    return none(string)

  return some(foundExes[0])

proc handleExec*(prioritizedExes: seq[string], args: seq[string]) {.noreturn.} =
  if len(prioritizedExes) != 0:
    let cargs = allocCStringArray(@[prioritizedExes[0].splitPath.tail] & args)


    for path in prioritizedExes:
      trace("execve: " & path & " " & args.join(" "))
      discard execv(cstring(path), cargs)
      # Either execv doesn't return, or something went wrong. No need to check the
      # error code.
      error("Chalk: when execing '" & path & "': " & $(strerror(errno)))

  error("Chalk: exec could not find a working executable to run.")
  quit(1)

var numCachedFds = 0

template bumpFdCount*(): bool =
  if numCachedFds < chalkConfig.getCacheFdLimit():
    numCachedFds = numCachedFds + 1
    true
  else:
    false

proc acquireFileStream*(chalk: ChalkObj): Option[FileStream] =
  ## Get a file stream to open the artifact pointed to by the chalk
  ## object. If it's in our cache, you'll get the cached copy. If
  ## it's expired, or the first time opening it, it'll be opened
  ## and added to the cache.
  ##
  ## Generally the codec doesn't worry about this... we use this API
  ## to acquire streams before passing the chalk object to any codec
  ## where the result of a call to usesFStream() is true (which is the
  ## default).
  ##
  ## If you're writing a plugin, not a codec, you should not rely on
  ## the presence of a file stream. Some codecs will not use them.
  ## However, if you want to use it anyway, you can, but you must
  ## test for it being nil.

  if chalk.stream == nil:
    var handle = newFileStream(chalk.fullpath, fmReadWriteExisting)
    if handle == nil:
      trace(chalk.fullpath & ": Cannot open for writing.")
      handle = newFileStream(chalk.fullPath, fmRead)
      if handle == nil:
        error(chalk.fullpath & ": could not open file for reading.")
        return none(FileStream)

    trace(chalk.fullpath & ": File stream opened")
    chalk.stream  = handle
    numCachedFds += 1
    return some(handle)
  else:
    trace(chalk.fullpath & ": existing stream acquired")
    result = some(chalk.stream)

proc closeFileStream*(chalk: ChalkObj) =
  ## This generally only gets called after we're totally done w/ the
  ## artifact.  Prior to that, when an operation finishes, we call
  ## yieldFileStream, which decides whether to cache or close.
  try:
    if chalk.stream != nil:
      chalk.stream.close()
      chalk.stream = nil
      trace(chalk.fullpath & ": File stream closed")
  except:
    warn(chalk.fullpath & ": Error when attempting to close file.")
    dumpExOnDebug()
  finally:
    chalk.stream = nil
    numCachedFds -= 1

proc yieldFileStream*(chalk: ChalkObj) =
  if numCachedFds == chalkConfig.getCacheFdLimit(): chalk.closeFileStream()
