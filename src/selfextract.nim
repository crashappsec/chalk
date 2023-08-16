import config, plugin_api

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
