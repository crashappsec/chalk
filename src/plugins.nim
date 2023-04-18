## This provides the base methods for plugins / codecs.
## Additionally, it provides utility functions to be used
## by plugins, as well as code for registering plugins.
##
## All of the data collection these plugins do is orchestrated in
## collect.nim
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, tables, strutils, algorithm, options, glob, streams,
       posix, std/tempfiles, nimSHA2, config, chalkjson

when (NimMajor, NimMinor) < (1, 7):  {.warning[LockLevel]: off.}

const  ePureVirtual = "Method is not defined; it must be overridden"

var
  installedPlugins: Table[string, Plugin]
  plugins:          seq[Plugin]           = @[]
  codecs:           seq[Codec]            = @[]

proc registerPlugin*(name: string, plugin: Plugin) =
  if name in installedPlugins:
    error("Double install of plugin named: " & name)
  plugin.name            = name
  installedPlugins[name] = plugin

proc validatePlugins() =
  for name, plugin in installedPlugins:
    let maybe = getPluginConfig(name)
    if maybe.isNone():
      error("No config provided for plugin " & name & ". Plugin ignored.")
      installedPlugins.del(name)
    elif not maybe.get().getEnabled():
      trace("Plugin " & name & " is disabled via config gile.")
      installedPlugins.del(name)
    else:
      plugin.configInfo = maybe.get()
      trace("Installed plugin: " & name)

proc getPlugins*(): seq[Plugin] =
  once:
    validatePlugins()
    var preResult: seq[(int, Plugin)] = @[]
    for name, plugin in installedPlugins:
      preResult.add((plugin.configInfo.getPriority(), plugin))

    preResult.sort()
    for (_, plugin) in preResult: plugins.add(plugin)

  return plugins

proc getCodecs*(): seq[Codec] =
  once:
    for item in getPlugins():
      if item.configInfo.codec: codecs.add(Codec(item))

  return codecs

var numCachedFds = 0

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
    let handle = newFileStream(chalk.fullpath, fmReadWriteExisting)
    if handle == nil:
      error(chalk.fullpath & ": could not open file.")
      return none(FileStream)

    trace(chalk.fullpath & ": File stream opened")
    chalk.stream  = handle
    numCachedFds += 1
    return some(handle)
  else:
    trace(chalk.fullpath & ": existing stream acquired")
    result = some(chalk.stream)

proc closeFileStream*(chalk: ChalkObj) =
  ## This only gets called after we're totally done w/ the artifact.
  ## Prior to that, when an operation finishes, we call yieldFileStream,
  ## which decides whether to cache or close.
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

proc loadChalkFromFStream*(stream: FileStream, loc: string): ChalkObj =
  ## A helper function for codecs that use file streams to load
  ## an existing chalk mark.  The stream must be positioned over
  ## the start of the Chalk magic before you call this function.

  result = newChalk(stream, loc)
  trace(result.fullpath & ": chalk mark magic @ " & $(stream.getPosition()))

  if not stream.findJsonStart():
    error(loc & ": Invalid JSON: found magic but no JSON start")
    return

  try:
    result.startOffset   = result.stream.getPosition()
    result.extract       = result.stream.extractOneChalkJson(result.fullpath)
    result.endOffset     = result.stream.getPosition()
  except:
    error(loc & ": Invalid JSON: " & getCurrentExceptionMsg())
    dumpExOnDebug()

# These are the base methods for all plugins.  They don't have to
# implement them; we only try to call these methods if the config for
# the plugin specifies that it returns keys from one of these
# particular calls.
method getChalkInfo*(self: Plugin, chalk: ChalkObj): ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getPostChalkInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
       ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getHostInfo*(self: Plugin, objs: seq[string], ins: bool):
       ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getPostRunInfo*(self: Plugin, objs: seq[ChalkObj]): ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)

# Base methods for codecs, including default implementations for things
# using file streams.

method usesFStream*(self: Codec): bool {.base.} = true

method scan*(self:   Codec,
             stream: FileStream,
             loc:    string): Option[ChalkObj] {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)

method keepScanningOnSuccess*(self: Codec): bool {.base.} = true

proc scanLocation(self:       Codec,
                  loc:        string,
                  exclusions: var seq[string]): Option[ChalkObj] =
  # Helper function for the default method scanArtifactLocations below.
  var stream = newFileStream(loc, fmRead)
  if stream == nil:
    error(loc & ": could not open file.")
    return
  else:
    trace(loc & ": File stream opened")
  result = self.scan(stream, loc)
  if result.isNone():
    stream.close()
    return
  exclusions.add(loc)
  var chalk = result.get()

  if numCachedFds < chalkConfig.getCacheFdLimit():
    numCachedFds = numCachedFds + 1
    chalk.stream = stream
  else:
    stream.close()
    trace(loc & ": File stream closed")

proc mustIgnore(path: string, globs: seq[glob.Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item): return true
  return false

method scanArtifactLocations*(self:       Codec,
                              exclusions: var seq[string],
                              ignoreList: seq[glob.Glob],
                              recurse:    bool): seq[ChalkObj] {.base.} =
  # If you want a simpler interface, this will call scan()
  # with a file stream, and you pass back a Chalk object if chalk is
  # there.  Otherwise, you can overload this if you want to skip
  # the file system walk.
  result = @[]

  for path in self.searchPath:
    trace("Codec " & self.name & ": beginning scan of " & path)
    var info: FileInfo
    try:
      info = getFileInfo(path)
    except:
      error("In codec '" & self.name & "': " & path &
            ": No such file or directory")
      dumpExOnDebug()
      continue

    if info.kind == pcFile:
      if path in exclusions:          continue
      if path.mustIgnore(ignoreList): continue
      trace(path & ": scanning file")
      let opt = self.scanLocation(path, exclusions)
      if opt.isSome():
        result.add(opt.get())
        opt.get().yieldFileStream()
    elif recurse:
      dirWalk(true):
        if item in exclusions:               continue
        if item.mustIgnore(ignoreList):      continue
        if getFileInfo(item).kind != pcFile: continue
        trace(item & ": scanning file")
        let opt = self.scanLocation(item, exclusions)
        if opt.isSome():
          result.add(opt.get())
          opt.get().yieldFileStream()
    else:
      dirWalk(false):
        if item in exclusions:               continue
        if item.mustIgnore(ignoreList):      continue
        if getFileInfo(item).kind != pcFile: continue
        trace("Non-recursive dir walk examining: " & item)
        let opt = self.scanLocation(item, exclusions)
        if opt.isSome():
          result.add(opt.get())
          opt.get().yieldFileStream()

method getArtifactHash*(self: Codec, chalk: ChalkObj): string {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)

method getHashAsOnDisk*(self: Codec, chalk: ChalkObj): Option[string] {.base.} =
  let s = chalk.acquireFileStream().getOrElse(nil)
  if s == nil: return none(string)

  result = some($(s.readAll().computeSHA256()))

  chalk.closeFileStream()

proc getChalkId*(self: Codec, chalk: ChalkObj): string =
  discard chalk.acquireFileStream()
  chalk.rawHash = self.getArtifactHash(chalk)
  result = idFormat(chalk.rawHash)

  chalk.yieldFileStream()

method getChalkInfo*(self: Codec, chalk: ChalkObj): ChalkDict =
  result               = ChalkDict()
  result["HASH_FILES"] = pack(@[chalk.fullpath])

method getPostChalkInfo*(self: Codec, chalk: ChalkObj, ins: bool): ChalkDict =
  result = ChalkDict()

  if chalk.postHash != "":
    result["_CURRENT_HASH"] = pack(chalk.postHash.toHex().toLowerAscii())
  else:
    let v = self.getHashAsOnDisk(chalk)
    if v.isSome():
      result["_CURRENT_HASH"] = pack(v.get().toHex().toLowerAscii())


## Codecs override this if they're for a binary format and can self-inject.
method getNativeObjPlatforms*(s: Codec): seq[string] {.base.} = @[]

proc replaceFileContents*(chalk: ChalkObj, contents: string) =
  var
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)

  try:
    ctx.write(contents)
  finally:
    if ctx != nil:
      try:
        ctx.close()
        moveFile(path, chalk.fullpath)
      except:
        removeFile(path)
        error(chalk.fullPath & ": Could not write (no permission)")
        dumpExOnDebug()

method handleWrite*(s:       Codec,
                    chalk:   ChalkObj,
                    enc:     Option[string],
                    virtual: bool): string {.base.} =
  var pre, post: string
  chalk.stream.setPosition(0)
  pre = chalk.stream.readStr(chalk.startOffset)
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
    post = chalk.stream.readAll()
  chalk.closeFileStream()
  let contents = pre & enc.getOrElse("") & post
  if not virtual:   chalk.replaceFileContents(contents)
  else:             publish("virtual", enc.get()) # Can't do virtual on delete.
  return $(contents.computeSHA256()).toHex().toLowerAscii()

# We need to turn off UnusedImport here, because the nim static
# analyzer thinks the below imports are unused. When we first import,
# they call registerPlugin(), which absolutely will get called.
{.warning[UnusedImport]: off.}

import plugins/codecShebang
import plugins/codecElf
import plugins/codecContainer
import plugins/codecZip
import plugins/ciGithub
import plugins/ciJenkins
import plugins/ciGitlab
import plugins/conffile
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/vctlGit
import plugins/externalTool
import plugins/system
