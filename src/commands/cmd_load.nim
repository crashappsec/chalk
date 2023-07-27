import posix, ../config, ../selfextract, ../collect, ../reporting,
       ../con4mfuncs, ../chalkjson, ../util, ../plugin_api

template cantLoad(s: string) =
  error(s)
  quit(1)

proc cmdlineError(err, tb: string): bool =
  error(err)
  return false

proc newConfFileError(err, tb: string): bool =
  error(err & "\n" & tb)
  return false

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

proc runCmdConfLoad*() =
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
    newCon4m = defaultConfig
    info("Installing the default configuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      cantLoad(filename & ": could not open configuration file")
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      dumpExOnDebug()
      cantLoad(filename & ": could not read configuration file")

    if chalkConfig.getValidateConfigsOnLoad():
      info(filename & ": Validating configuration.")
      if chalkConfig.getValidationWarning():
        warn("Note: validation involves creating a new configuration context"  &
             " and evaluating your code to make sure it at least evaluates "   &
             "fine on a default path.  subscribe() and unsubscribe() will "    &
             "ignore any calls, but if your config always shells out, it will" &
             " happen here.  To skip error checking, you can add "             &
             "--no-validation.  But, if there's a basic error, chalk may not " &
             "run without passing --no-use-embedded-config.  Suppress this "       &
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
      stack.run()
      startTestRun()
      stack.addConfLoad(filename, toStream(newCon4m)).run()
      endTestRun()

      if not stack.errored:
        trace(filename & ": Configuration successfully validated.")
      else:
        addUnmarked(selfChalk.fullPath)
        selfChalk.opFailed = true
        doReporting()
        return
    else:
      trace("Skipping configuration validation.")

  selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)
  selfChalk.collectChalkInfo()

  trace(filename & ": installing configuration.")

  let toWrite = some(selfChalk.getChalkMarkAsStr())
  selfChalk.myCodec.handleWrite(selfChalk, toWrite)

  if selfChalk.opFailed:
    warn(selfChalk.fullPath & ": unable to modify file.")
    warn("Attempting to write to: " & selfChalk.fullPath & ".new")
    selfChalk.opFailed = false
    selfChalk.fullPath = selfChalk.fullPath & ".new"
    selfChalk.closeFileStream()
    discard selfChalk.acquireFileStream()
    selfChalk.myCodec.handleWrite(selfChalk, toWrite)
    if selfChalk.opFailed:
      error("Failed to write. Operation aborted.")
      return
    else:
      when defined(posix):
        let f = open(selfChalk.fullPath)
        f.makeExecutable()
        f.close()

  info("Configuration replaced in binary: " & selfChalk.fullPath)
  doReporting()
