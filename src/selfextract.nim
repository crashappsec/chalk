##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Code specific to reading and writing Chalk's own chalk mark.

import config, httpclient, plugin_api, posix, collect, con4mfuncs, chalkjson, util, uri, nimutils/sinks

proc handleSelfChalkWarnings*() =
  if not canSelfInject:
    warn("We have no codec for this platform's native executable type")
  else:
    if not selfChalk.isMarked():
        warn("No existing self-chalk mark found.")
    elif "CHALK_ID" notin selfChalk.extract:
        error("Self-chalk mark found, but is invalid.")

proc getSelfExtraction*(): Option[ChalkObj] =
  # If we call twice and we're on a platform where we don't
  # have a codec for this type of executable, avoid dupe errors.
  once:
    var
      myPath = @[resolvePath(getMyAppPath())]
      cmd    = getCommandName()

    setCommandName("extract")

    # This can stay here, but won't show if the log level is set in the
    # config file, since this function runs before the config files load.
    # It will only be seen if running via --trace.
    #
    # Also, note that this function extracts any chalk, but our first
    # caller, getEmbededConfig() in config.nim, checks the results to
    # see if the mark is there, and reports whether it's found or not.
    # This trace happens here mainly because we easily have the
    # resolved path here.
    trace("Checking chalk binary '" & myPath[0] & "' for embedded config")

    for codec in getAllCodecs():
      if hostOS notin codec.nativeObjPlatforms:
        continue
      let
        ai     = ArtifactIterationInfo(filePaths: myPath)
        chalks = codec.scanArtifactLocations(ai)

      if len(chalks) == 0:
        continue

      selfChalk = chalks[0]
      break

    if selfChalk == nil:
      canSelfInject = false
      setCommandName(cmd)
      return none(ChalkObj)

    if selfChalk.extract == nil:
      selfChalk.marked = false
      selfChalk.extract = ChalkDict()

      selfId = some(selfChalk.callGetChalkId())

    setCommandName(cmd)

  if selfChalk != nil:
    result = some(selfChalk)
  else:
    result = none(ChalkObj)

template selfChalkGetKey*(keyName: string): Option[Box] =
  if selfChalk == nil or selfChalk.extract == nil or
     keyName notin selfChalk.extract:
    none(Box)
  else:
    some(selfChalk.extract[keyName])

# The rest of this is specific to writing the self-config.
template cantLoad*(s: string) =
  error(s)
  quit(1)

proc newConfFileError(err, tb: string): bool =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    error(err & "\n" & tb)
  else:
    error(err)

  quit(1)

proc makeExecutable(f: File) =
  ## Todo: this can move to nimutils actually.
  when defined(posix):
    let fd = f.getOsFileHandle()
    var statRes: Stat
    var mode:    int

    if fstat(fd, statRes) == 0:
      mode = int(statRes.st_mode)
      if (mode and 0x6000) != 0:
        mode = mode or 0x100
      else:
        mode = mode or 0x111

      discard fchmod(fd, Mode(mode))

proc writeSelfConfig*(selfChalk: ChalkObj): bool
    {.cdecl, exportc, discardable.} =
  selfChalk.persistInternalValues()
  collectChalkTimeHostInfo()

  let lastCount = if "$CHALK_LOAD_COUNT" notin selfChalk.collectedData:
                    -1
                  else:
                    unpack[int](selfChalk.collectedData["$CHALK_LOAD_COUNT"])

  selfChalk.collectedData["$CHALK_LOAD_COUNT"]          = pack(lastCount + 1)
  selfChalk.collectedData["$CHALK_IMPLEMENTATION_NAME"] = pack(implName)
  selfChalk.collectChalkTimeArtifactInfo()

  trace(selfChalk.name & ": installing configuration.")

  let toWrite = some(selfChalk.getChalkMarkAsStr())
  selfChalk.callHandleWrite(toWrite)

  if selfChalk.opFailed:
    let
      (path, fname) = selfChalk.fsRef.splitPath()
      maybe         = getCurrentDir().joinPath(fname)
      actual        = if maybe == selfChalk.fsRef:
                        selfChalk.fsRef & ".new"
                      else:
                        maybe

    warn(selfChalk.fsRef & ": unable to modify file.")
    warn("Attempting to write a copy of the binary with the new config to: " &
         actual)
    selfChalk.opFailed = false
    selfChalk.fsRef    = actual
    selfChalk.chalkCloseStream()

    selfChalk.callHandleWrite(toWrite)
    if selfChalk.opFailed:
      error("Failed to write. Operation aborted.")
      return false
    else:
      when defined(posix):
        let f = open(selfChalk.fsRef)
        f.makeExecutable()
        f.close()

  info("Configuration replaced in binary: " & selfChalk.fsRef)
  selfChalk.makeNewValuesAvailable()
  return true

template loadConfigFile*(filename: string) =
  let f = newFileStream(resolvePath(filename))
  if f == nil:
    cantLoad(filename & ": could not open configuration file")
  loadConfigStream(filename, f)

template loadConfigUrl*(url: string) =
  let uri = parseUri(url)
  var stream: Stream
  try:
    let
      client   = newHttpClient(timeout = 5000) # 5 seconds
      response = client.safeRequest(uri)
    stream = response.bodyStream

  except:
    dumpExOnDebug()
    cantLoad(url & ": could not request configuration")

  loadConfigStream(url, stream)

template loadConfigStream*(name: string, stream: Stream) =
  try:
    newCon4m = stream.readAll()
    if selfChalk.extract != nil:
      # Overwrite what we extracted, as it'll get "preserved" when
      # writing out the chalk file.
      selfChalk.extract["$CHALK_CONFIG"] = pack(newCon4m)
    else:
      selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)

  except:
    dumpExOnDebug()
    cantLoad(name & ": could not read configuration")

  finally:
    stream.close()

template testConfigFile*(filename: string, newCon4m: string) =
  info(filename & ": Validating configuration.")
  if chalkConfig.getValidationWarning():
    warn("Note: validation involves creating a new configuration context"  &
         " and evaluating your code to make sure it at least evaluates "   &
         "fine on a default path.  subscribe() and unsubscribe() will "    &
         "ignore any calls, but if your config always shells out, it will" &
         " happen here.  To skip error checking, you can add "             &
         "--no-validation.  But, if there's a basic error, chalk may not " &
         "run without passing --no-use-embedded-config.  Suppress this "   &
         "message in the future by setting `no_validation_warning` in the" &
         " config, or passing --no-validation-warning on the command line.")

  let
    toStream = newStringStream
    stack    = newConfigStack().addSystemBuiltins().
               addCustomBuiltins(chalkCon4mBuiltins).
               addGetoptSpecLoad().
               addSpecLoad(chalkSpecName, toStream(chalkC42Spec)).
               addConfLoad(baseConfName, toStream(baseConfig)).
               setErrorHandler(newConfFileError).
               addConfLoad(ioConfName,   toStream(ioConfig))
  try:
    # Test Run will cause (un)subscribe() to ignore subscriptions, and
    # will suppress log messages, etc.
    stack.run()
    startTestRun()
    stack.addConfLoad(filename, toStream(newCon4m)).run()
    endTestRun()
    if stack.errored:
      quit(1)
  except:
    dumpExOnDebug()
    error(getCurrentExceptionMsg() & "\n")
    quit(1)
