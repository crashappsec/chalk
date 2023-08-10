import posix, ../config, ../selfextract, ../collect, ../reporting,
       ../con4mfuncs, ../chalkjson, ../util, ../plugin_api

template cantLoad(s: string) =
  error(s)
  quit(1)

proc newConfFileError(err, tb: string): bool =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    error(err & "\n" & tb)
  else:
    error(err)

  quit(1)

proc makeExecutable(f: File) =
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

proc persistInternalValues(chalk: ChalkObj) =
  if chalk.extract == nil:
    return
  for item, value in chalk.extract:
    if item.startsWith("$"):
      chalk.collectedData[item] = value

proc makeNewValuesAvailable(chalk: ChalkObj) =
  if chalk.extract == nil:
    chalk.extract = ChalkDict()
  for item, value in chalk.collectedData:
    if item.startsWith("$"):
      chalk.extract[item] = value

proc writeSelfConfig*(selfChalk: ChalkObj) =
  selfChalk.persistInternalValues()
  collectChalkTimeHostInfo()
  selfChalk.collectChalkTimeArtifactInfo()

  let lastCount = if "$CHALK_LOAD_COUNT" notin selfChalk.collectedData:
                    -1
                  else:
                    unpack[int](selfChalk.collectedData["$CHALK_LOAD_COUNT"])

  selfChalk.collectedData["$CHALK_LOAD_COUNT"]          = pack(lastCount + 1)
  selfChalk.collectedData["$CHALK_IMPLEMENTATION_NAME"] = pack(implName)

  trace(selfChalk.name & ": installing configuration.")

  let toWrite = some(selfChalk.getChalkMarkAsStr())
  selfChalk.myCodec.handleWrite(selfChalk, toWrite)

  if selfChalk.opFailed:
    warn(selfChalk.fsRef & ": unable to modify file.")
    warn("Attempting to write a copy to: " & selfChalk.fsRef & ".new")
    selfChalk.opFailed = false
    selfChalk.fsRef = selfChalk.fsRef & ".new"
    selfChalk.closeFileStream()
    discard selfChalk.acquireFileStream()
    selfChalk.myCodec.handleWrite(selfChalk, toWrite)
    if selfChalk.opFailed:
      error("Failed to write. Operation aborted.")
      return
    else:
      when defined(posix):
        let f = open(selfChalk.fsRef)
        f.makeExecutable()
        f.close()

  info("Configuration replaced in binary: " & selfChalk.fsRef)
  selfChalk.makeNewValuesAvailable()

template loadConfigFile(filename: string) =
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      cantLoad(filename & ": could not open configuration file")
    try:
      newCon4m = f.readAll()
      f.close()
      selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)
    except:
      dumpExOnDebug()
      cantLoad(filename & ": could not read configuration file")

template testConfigFile(filename: string, newCon4m: string) =
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

proc runCmdConfLoad*() =
  setContextDirectories(@["."])
  initCollection()

  var newCon4m: string

  let filename = getArgs()[0]

  if filename == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCstringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  if filename == "default":
    if selfChalk.isMarked() and "$CHALK_CONFIG" notin selfChalk.collectedData:
        cantLoad("Already using the default configuration.")
    newCon4m = defaultConfig
    info("Installing the default configuration file.")
  else:
    loadConfigFile(filename)
    trace(filename & ": Configuration successfully validated.")
    if chalkConfig.getValidateConfigsOnLoad():
      testConfigFile(filename, newCon4m)
    else:
      warn("Skipping configuration validation. This could break chalk.")

  selfChalk.writeSelfConfig()
  doReporting()
