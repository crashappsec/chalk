##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Code specific to reading and writing Chalk's own chalk mark.

import config, plugin_api, posix, collect, con4mfuncs, chalkjson, util,
       docker_base

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
      myPath = getMyAppPath()
      cmd    = getCommandName()

    try:
      myPath = myPath.resolvePath()
    except:
      # should not happen as getMyAppPath should return absolute path
      # however resolvePath can fail in some cases such as when
      # path contains ~ but uid does not have home directory
      discard

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
    trace("Checking chalk binary '" & myPath & "' for embedded config")

    # Codecs by design fail gracefully as self config can be
    # encoded using any codec (e.g. elf on linux but shell script on mac).
    # Therefore if none of the codecs reads/parses config
    # from the chalk binary, chalk will proceed running
    # using default configs.
    # There are 2 cases however where there are no embedded configs:
    # * chalk binary was just compiled (before chalk load)
    # * codecs could not read the chalk binary
    #   due to missing permissions but graceful error handling
    #   does not raise an exception
    # In the case of missing permission, chalk using default
    # configs is incorrect behavior therefore we explicitly
    # check permission by opening a file stream.
    # If that works, world is amazing and llamas have lots
    # of lettus to enjoy ;D
    # If not, we immediately exit with hopefully useful error message
    # :fingerscrossed:
    if not canOpenFile(myPath):
      cantLoad("Chalk is unable to read self-config. " &
               "Ensure chalk has both read and execute permissions. " &
               "To add permissions run: 'chmod +rx " & myPath & "'\n")

    for codec in getAllCodecs():
      if hostOS notin codec.nativeObjPlatforms:
        continue
      let
        ai     = ArtifactIterationInfo(filePaths: @[myPath])
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

proc testConfigFile*(uri: string, newCon4m: string, params: seq[Box]):
                   ConfigState =
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
    stack    = newConfigStack().
               addSystemBuiltins().
               addCustomBuiltins(chalkCon4mBuiltins).
               addGetoptSpecLoad().
               addSpecLoad(chalkSpecName,  toStream(chalkC42Spec)).
               addConfLoad(baseConfName,   toStream(baseConfig)).
               setErrorHandler(newConfFileError).
               addConfLoad(ioConfName,     toStream(ioConfig)).
               addConfLoad(attestConfName, toStream(attestConfig)).
               addConfLoad(sbomConfName,   toStream(sbomConfig)).
               addConfLoad(sastConfName,   toStream(sastConfig)).
               addConfLoad(coConfName,     toStream(coConfig))
  try:
    # Test Run will cause (un)subscribe() to ignore subscriptions, and
    # will suppress log messages, etc.
    stack.run()
    for item in params:
      let
        row     = unpack[seq[Box]](item)
        attr    = unpack[bool](row[0])
        url     = unpack[string](row[1])
        sym     = unpack[string](row[2])
        c4mType = toCon4mType(unpack[string](row[3]))
        value   = row[4]
      if attr:
        stack.configState.setAttributeParamValue(url, sym, value, c4mType)
      else:
        stack.configState.setVariableParamValue(url, sym, value, c4mType)

    startTestRun()
    stack.addConfLoad(uri, toStream(newCon4m))
    stack.run()
    endTestRun()
    if stack.errored:
      quit(1)
    info(uri & ": Configuration successfully validated.")
    return stack.configState
  except:
    dumpExOnDebug()
    cantLoad(getCurrentExceptionMsg() & "\n")

proc toBox(param: ParameterInfo, component: ComponentInfo): Box =
  # Though you can pack / unpack con4m types, we don't have a JSON
  # mapping for them, so it's best for now to just pack the string
  # repr and re-parse it on the other end.
  var arr = @[pack(param.name in component.attrParams),
              pack(component.url),
              pack(param.name),
              pack($(param.defaultType)),
              param.value.get()]
  return pack(arr)

proc addParam(params: var seq[Box], param: ParameterInfo, component: ComponentInfo) =
  params.add(param.toBox(component))

proc addParams(params: var seq[Box], component: ComponentInfo) =
  for _, v in component.varParams:
    params.addParam(v, component)
  for _, v in component.attrParams:
    params.addParam(v, component)

const nocache = [getoptConfName,
                 baseConfName,
                 sbomConfName,
                 sastConfName,
                 ioConfName,
                 attestConfName,
                 defCfgFname,
                 coConfName,
                 embeddedConfName]

proc updateArchBinaries*(newConfig: string, newParams: seq[Box],
                         bins: TableRef[string, string] = nil) =
  var binInfo: TableRef[string, string]

  if bins != nil:
    binInfo = bins
  elif not chalkConfig.loadConfig.getUpdateArchBinaries():
    return
  else:
    binInfo = chalkConfig.dockerConfig.getArchBinaryLocations().getOrElse(nil)

  if binInfo == nil or len(binInfo) == 0:
    trace("No multi-arch binaries to load.")
    return
  for arch, unresolvedLocation in binInfo:
    let location = unresolvedLocation.resolvePath()

    info("Attempting to update config for architecture: " & arch & " (" &
      location & ")")
    let
      (dir, fname) = location.splitPath()
      confLoc      = dir.joinPath("config.c4m")

    if not tryToWriteFile(confLoc, newConfig):
      warn("Could not write config to: " & confLoc)
      continue

    let
      chalkMnt = location & ":/chalk"
      confMnt  = confLoc & ":/config.c4m"
      ctrCmd   = "chmod +x /chalk && /chalk load --replace /config.c4m"
      arch     = "linux/" & arch
      args     = @[ "run", "--rm", "--platform", arch, "-v", chalkMnt, "-v",
                    confMnt, "alpine", "sh", "-c", ctrCmd]
      output = runDockerGetEverything(args, stdin = boxToJson(pack(newParams)))

    if output.getExit() != 0:
      warn("Docker command to update config for archiecture " & arch &
        " failed: " & output.getStderr())
      continue
    else:
      info("Successfully updated config for architecture " & arch)

proc handleConfigLoad*(inpath: string) =
  assert selfChalk != nil

  var path: string

  if inpath.endswith(".c4m"):
    path = inpath
  else:
    path = inpath & ".c4m"

  if fileExists(path):
    path = inpath.resolvePath()
  else:
    path = inpath

  let
    validate          = chalkConfig.loadConfig.getValidateConfigsOnLoad()
    replace           = chalkConfig.loadConfig.getReplaceConf()
    confPaths         = chalkConfig.getConfigPath()
    confFilename      = chalkConfig.getConfigFilename()

  if replace:
    info("Replacing base configuration with module from: " & path)
    selfChalkDelKey("$CHALK_CONFIG")
    selfChalkDelKey("$CHALK_COMPONENT_CACHE")
    selfChalkDelKey("$CHALK_SAVED_COMPONENT_PARAMETERS")
  else:
    info("Attempting to load module from: " & path)

  let
    runtime           = getChalkRuntime()
    alreadyCached     = haveComponentFromUrl(runtime, path).isSome()
    (base, module, _) = path.fullUrlToParts()
    curConfOpt        = selfChalkGetKey("$CHALK_CONFIG")

  var
    component: ComponentInfo
    testState: ConfigState

  try:
    component  = runtime.loadComponentFromUrl(path)
  except:
    dumpExOnDebug()
    cantLoad(getCurrentExceptionMsg() & "\n")

  var
    newComponents = component.getUsedComponents()
    newEmbedded:    string

  if replace or curConfOpt.isNone():
    newEmbedded = ""
  else:
    newEmbedded = unpack[string](curConfOpt.get())

  if not alreadyCached or replace:
    let
      useLine = "use " & module  & " from \"" & base & "\""
      withUse = newEmbedded & "\n" & useLine
    newEmbedded = withUse.strip()

  if chalkConfig.loadConfig.getParamsViaStdin():
    try:
      let
        chalkJsonTree = newStringStream(stdin.readLine()).chalkParseJson()
        runtime       = getChalkRuntime()

      if chalkJsonTree.kind != CJArray:
        raise newException(IOError, "")
      for row in chalkJsonTree.items:
        if row.kind != CJArray or row.items.len() != 5:
          raise newException(IOError, "")
        let
          attr    = row.items[0].boolval
          url     = row.items[1].strval
          sym     = row.items[2].strval
          c4mType = row.items[3].strval.toCon4mType()
          value   = row.items[4].jsonNodeToBox()
        if attr:
          runtime.setAttributeParamValue(url, sym, value, c4mType)
        else:
          runtime.setVariableParamValue(url, sym, value, c4mType)
    except:
      error("Invalid json parameters via stdin: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      quit(1)
  elif validate:
    let prompt = "Press [enter] to check your configuration for conflicts."
    runtime.basicConfigureParameters(component, newComponents, prompt)
  else:
    runtime.basicConfigureParameters(component, newComponents)

  # Load any saved parameters; we will pass them off to any testing
  var
    componentsToTest = runtime.programRoot.getUsedComponents(paramOnly = true)
    paramsToTest:    seq[Box]

  for item in newComponents:
    if item notin componentsToTest:
      componentsToTest.add(item)

  for item in componentsToTest:
    paramsToTest.addParams(item)

  if validate:
    # need to test with another top-level config name
    # otherwise cycle is bound to be detected
    testState = testConfigFile("[testing config]", newEmbedded, paramsToTest)
    assert testState != nil
  else:
    warn("Skipping configuration validation. This could break chalk.")

  # Now, load the code cache/params.
  var
    cachedCode =      OrderedTableRef[string, string]()
    paramsToSave:     seq[Box]
    componentsToSave: seq[ComponentInfo]

  if replace:
    # when replacing only honor used tested components
    # as that will only include loaded component+its deps
    componentsToSave = componentsToTest
  else:
    # save all params across all components, if any
    # as previous configuration could have existing params
    # which we cannot delete if we only save params used for testing
    for _, item in runtime.components:
      componentsToSave.add(item)

  for _, item in componentsToSave:
    paramsToSave.addParams(item)
    if item.url in nocache:
      continue
    if item.source == "":
      continue
    try:
      let (head, tail) = item.url.splitPath()
      # dont cache external configs
      if head in confPaths and tail == confFilename:
        continue
    except:
      # in case splitPath fails for some obscure urls?
      discard
    cachedCode[item.url] = item.source

  selfChalkSetKey("$CHALK_CONFIG", pack(newEmbedded))
  selfChalkSetKey("$CHALK_COMPONENT_CACHE", pack(cachedCode))
  selfChalkSetKey("$CHALK_SAVED_COMPONENT_PARAMETERS", pack(paramsToSave))

  if testState != nil:
    let archOpt: Option[TableRef[string, string]] =
      getOpt[TableRef[string, string]](testState, "docker.arch_binary_locations")
    if archOpt.isSome():
      updateArchBinaries(newEmbedded, paramsToSave, archOpt.get())
      return

  updateArchBinaries(newEmbedded, paramsToSave)
