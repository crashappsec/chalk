##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Code specific to reading and writing Chalk's own chalk mark.

import config, plugin_api, posix, collect, con4mfuncs, chalkjson, util

proc handleSelfChalkWarnings*() =
  if not canSelfInject:
    warn("We have no codec for this platform's native executable type")
  else:
    if not selfChalk.isMarked():
        warn("No existing self-chalk mark found.")
    elif "CHALK_ID" notin selfChalk.extract:
        error("Self-chalk mark found, but is invalid.")

template cantLoad*(s: string) =
  error(s)
  quit(1)


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

proc selfChalkGetKey*(keyName: string): Option[Box] =
  if selfChalk == nil or selfChalk.extract == nil or
     keyName notin selfChalk.extract:
    return none(Box)
  else:
    return some(selfChalk.extract[keyName])

proc selfChalkSetKey*(keyName: string, val: Box) =
  if selfChalk.extract != nil:
    # Overwrite what we extracted, as it'll get "preserved" when
    # writing out the chalk file.
    selfChalk.extract[keyName] = val
  selfChalk.collectedData[keyName] = val

proc selfChalkDelKey*(keyName: string) =
  if selfChalk.extract != nil and keyName in selfChalk.extract:
     selfChalk.extract.del(keyName)
  if keyName in selfChalk.collectedData:
    selfChalk.collectedData.del(keyName)

# The rest of this is specific to writing the self-config.

proc newConfFileError(err, tb: string): bool =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    cantLoad(err & "\n" & tb)
  else:
    cantLoad(err)

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
  selfChalk.persistInternalValues()   # Found in run_management.nim
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
      (_, fname) = selfChalk.fsRef.splitPath()
      maybe      = getCurrentDir().joinPath(fname)
      actual     = if maybe == selfChalk.fsRef:
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

proc testConfigFile*(uri: string, newCon4m: string) =
  info(uri & ": Validating configuration.")
  if chalkConfig.loadConfig.getValidationWarning():
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
               addConfLoad(ioConfName,   toStream(ioConfig)).
               addConfLoad(attestConfName, toStream(attestConfig)).
               addConfLoad(sbomConfName, toStream(sbomConfig)).
               addConfLoad(sastConfName, toStream(sastConfig))
  try:
    # Test Run will cause (un)subscribe() to ignore subscriptions, and
    # will suppress log messages, etc.
    stack.run()
    startTestRun()
    stack.addConfLoad(uri, toStream(newCon4m)).run()
    endTestRun()
    if stack.errored:
      quit(1)
    info(uri & ": Configuration successfully validated.")
  except:
    dumpExOnDebug()
    cantLoad(getCurrentExceptionMsg() & "\n")

proc paramsToBox(a: bool, b, c: string, d: Con4mType, e: Box): Box =
  # Though you can pack / unpack con4m types, we don't have a JSON
  # mapping for them, so it's best for now to just pack the string
  # repr and re-parse it on the other end.
  var arr = @[ pack(a), pack(b), pack(c), pack($(d)), e ]
  return pack(arr)

proc handleConfigLoad*(path: string) =
  assert selfChalk != nil

  let
    runtime          = getChalkRuntime()
    alreadyCached    = haveComponentFromUrl(runtime, path).isSome()
    (uri, module, _) = path.fullUrlToParts()
    curConfOpt       = selfChalkGetKey("$CHALK_CONFIG")

  var
    component: ComponentInfo
    replace:   bool

  try:
    component  = runtime.loadComponentFromUrl(path)
    replace    = chalkConfig.loadConfig.getReplaceConf()

  except:
    dumpExOnDebug()
    cantLoad(getCurrentExceptionMsg() & "\n")

  var
    toConfigure = component.getUsedComponents(paramOnly = true)
    newEmbedded: string

  if replace or curConfOpt.isNone():
    newEmbedded = ""
  else:
    newEmbedded = unpack[string](curConfOpt.get())

  if not alreadyCached:
    if not newEmbedded.endswith("\n"):
      newEmbedded.add("\n")

    newEmbedded.add("use " & module & " from \"" & uri & "\"\n")

  if len(toConfigure) == 0:
    info("Attempting to replace base configuration from: " & path)
  else:
    info("Attempting to load configuration module from: " & path)
    runtime.basicConfigureParameters(component, toConfigure)

  if replace or alreadyCached == false:
    # If we just reconfigured a component, then we don't bother testing.
    if chalkConfig.loadConfig.getValidateConfigsOnLoad():
      testConfigFile(path, newEmbedded)
    else:
      warn("Skipping configuration validation. This could break chalk.")

    selfChalkSetKey("$CHALK_CONFIG", pack(newEmbedded))

  # Now, load the code cache.
  var cachedCode = OrderedTableRef[string, string]()

  for name, component in runtime.components:
    if component.source != "":
      cachedCode[name] = component.source

  # Load any saved parameters.
  var
    allComponents = runtime.programRoot.getUsedComponents()
    params: seq[Box]

  for item in toConfigure:
    if item notin allComponents:
      allComponents.add(item)

  for component in allComponents:
    for _, v in component.varParams:
      params.add(paramsToBox(false, component.url, v.name, v.defaultType,
                             v.value.get()))


    for _, v in component.attrParams:
      params.add(paramsToBox(true, component.url, v.name, v.defaultType,
                             v.value.get()))

  selfChalkSetKey("$CHALK_COMPONENT_CACHE", pack(cachedCode))
  selfChalkSetKey("$CHALK_SAVED_COMPONENT_PARAMETERS", pack(params))
