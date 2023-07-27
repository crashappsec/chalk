import config, collect, plugin_api

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
      exclusions: seq[string] = @[]
      chalks:     seq[ChalkObj]
      ignore:     bool

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

    for codec in getCodecs():
      if hostOS notin codec.getNativeObjPlatforms(): continue
      (ignore, chalks)  = codec.findChalk(myPath, exclusions, @[], false)
      selfChalk         = chalks[0]
      if selfChalk.extract == nil:
        selfChalk.marked = false
        selfChalk.extract = ChalkDict()
      selfId            = some(codec.getChalkId(selfChalk))
      selfChalk.myCodec = codec
      return some(selfChalk)

    canSelfInject = false

  if selfChalk != nil: return some(selfChalk)
  else:                return none(ChalkObj)
