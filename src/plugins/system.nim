## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import nativesockets, nimSHA2, sequtils, times, ../config, ../plugin_api,
       ../normalize, ../chalkjson

when defined(posix): import posix_utils

type
  SystemPlugin* = ref object of Plugin
  MetsysPlugin* = ref object of Plugin

let
  signSig   = "sign(string) -> tuple[string, dict[string, string]]"
  verifySig = "verify(string, string, dict[string, string]) -> bool"

proc validateMetadata(obj: ChalkObj): bool =
  result     = false
  let fields = obj.extract

  # Re-compute the chalk ID.
  if fields == nil or len(fields) == 0:
    if getCommandName() == "extract":
      warn(obj.fullPath & ": can't validate; no extract.")
    return
  elif "CHALK_ID" notin fields:
    error(obj.fullPath & ": extracted chalk mark missing CHALK_ID field")
    return
  elif obj.myCodec.getChalkID(obj) != unpack[string](fields["CHALK_ID"]):
    error(obj.fullPath & ": extracted CHALK_ID doesn't match computed CHALK_ID")
    error(obj.myCodec.getChalkID(obj) & " vs: " &
      unpack[string](fields["CHALK_ID"]))
    return
  elif "METADATA_HASH" notin fields:
    error(obj.fullPath & ": extracted chalk mark missing METADATA_HASH field")
    return
  var
    toHash   = fields.normalizeChalk()
    computed = hashFmt($(toHash.computeSHA256()))

  if computed != unpack[string](fields["METADATA_HASH"]):
    error(obj.fullPath & ": extracted METADATA_HASH doesn't validate")

  elif "SIGNATURE" notin fields:
    if "SIGNING" in fields and unpack[bool](fields["SIGNING"]):
      error(obj.fullPath & ": SIGNING was set, but SIGNATURE was not found")
  else:
    let artHash = obj.myCodec.getUnchalkedHash(obj)

    if artHash.isSome():
      let
        toVerify = pack(artHash.get() & "\n" & computed & "\n")
        args     = @[toVerify, fields["SIGNATURE"], fields["SIGN_PARAMS"]]
        optValid = runCallback(verifySig, args)

      if optValid.isSome():
        result = unpack[bool](optValid.get())
        if not result:
          error(obj.fullPath & ": signature verification failed.")
        else:
          info(obj.fullPath & ": signature successfully verified.")
          return true
      else:
        once(warn(obj.fullPath & ": no signature validation routine provided."))

# Even if you don't subscribe to TIMESTAMP we collect it in case
# you're subscribed to something that uses it in a substitution.
method getChalkTimeArtifactInfo*(self: SystemPlugin, obj: ChalkObj): ChalkDict =
  result              = ChalkDict()
  result["MAGIC"]     = pack(magicUTF8)
  result["TIMESTAMP"] = pack(unixTimeInMS())

  if obj.isMarked() and "METADATA_HASH" in obj.extract:
    let h = unpack[string](obj.extract["METADATA_HASH"]).strip().parseHexStr()

    result.setIfSubscribed("OLD_CHALK_METADATA_HASH",
                           obj.extract["METADATA_HASH"])

    result.setIfSubscribed("OLD_CHALK_METADATA_ID", idFormat(h))

proc applySubstitutions(obj: ChalkObj) {.inline.} =
  # Apply {}-style substitutions to artifact chalking keys where appropriate.
  let
    chalkId   = unpack[string](obj.lookupCollectedKey("CHALK_ID").get())
    now       = $(unpack[int](obj.lookupCollectedKey("TIMESTAMP").get()))
    path      = unpack[string](obj.lookupCollectedKey("ARTIFACT_PATH").get())
    `hash?`   = obj.lookupCollectedKey("HASH")
    `tenant?` = obj.lookupCollectedKey("TENANT_ID")
    `random?` = obj.lookupCollectedKey("CHALK_RAND")
  var
    subs      = @[("{chalk_id}", chalkId), ("{now}", now), ("{path}", path)]

  if `tenant?`.isSome(): subs.add(("{tenant}", unpack[string](`tenant?`.get())))
  if `random?`.isSome(): subs.add(("{random}", unpack[string](`random?`.get())))
  if `hash?`.isSome():   subs.add(("{hash}",   unpack[string](`hash?`.get())))

  for k, v in obj.collectedData:
    if v.kind != MkStr: continue    # If it's not a string object, no sub to do.
    let spec = k.getKeySpec().get() # Should have crashed by now if false :)
    if not spec.applySubstitutions: continue
    let s = unpack[string](v)
    if not s.contains("{"): continue
    obj.collectedData[k] = pack(s.multiReplace(subs))

method getRunTimeArtifactInfo*(self: SystemPlugin,
                               obj:  ChalkObj,
                               ins:  bool): ChalkDict =
  result = ChalkDict()

  if not ins:
    obj.opFailed         = obj.validateMetadata()
    result["_VALIDATED"] = pack(obj.opFailed)

    if isSubscribedKey("_OP_ARTIFACT_PATH"):
      if obj.noResolvePath:
        result["_OP_ARTIFACT_PATH"] = pack(obj.fullPath)
      else:
        result["_OP_ARTIFACT_PATH"] = pack(resolvePath(obj.fullPath))
  else:
    obj.applySubstitutions()
    if obj.isMarked(): discard obj.validateMetadata()
    result.setIfSubscribed("_OP_CHALKED_KEYS", toSeq(obj.getChalkMark().keys))
    result.setIfSubscribed("_VIRTUAL",         chalkConfig.getVirtualChalk())

  var
    config     = getOutputConfig()
    reportName = config.artifactReport

  if obj.opFailed and config.invalidChalkReport != "":
    reportName = config.invalidChalkReport

  if reportName != "":
    let
      profile    = chalkConfig.profiles[reportName]
      report     = hostInfo.filterByProfile(obj.collectedData, profile)
      reportKeys = pack(toSeq(report.keys))

    result["_OP_ARTIFACT_REPORT_KEYS"] = pack(reportKeys)


var
  instant   = epochTime()
  timestamp = instant.fromUnixFloat()
  envdict:          Con4mDict[string, string]
  cachedSearchPath: seq[string] = @[]

when defined(posix):
  let uinfo = uname()

template getDate(): string     = timestamp.format("yyyy-MM-dd")
template getTime(): string     = timestamp.format("HH:mm:ss") & "." &
                                   timestamp.format("fff")
template getOffset(): string   = timestamp.format("zzz")
template getDateTime(): string = getDate() & "T" & getTime() & getOffset()

proc getEnvDict(): Box =
  once:
    envdict = Con4mDict[string, string]()
    let
      always = chalkConfig.getEnvAlwaysShow()
      never  = chalkConfig.getEnvNeverShow()
      redact = chalkConfig.getEnvRedact()
      def    = chalkConfig.getEnvDefaultAction()[0]

    for (k, v) in envPairs():
      # TODO: could add some con4m to warn on overlap across these 3. For now,
      # we treat it conservatively.
      if k in never:    continue
      elif k in redact: envdict[k] = "<<redact>>"
      elif k in always: envdict[k] = v
      elif def == 'n':  continue
      elif def == 'r':  envdict[k] = "<<redact>>"
      else: envdict[k] = v

  return pack(envdict)

method getRunTimeHostInfo*(self: SystemPlugin, objs: seq[ChalkObj]): ChalkDict =
  result = ChalkDict()

  if len(systemErrors)  != 0:
    result.setIfSubscribed("_OP_ERRORS", systemErrors)

  if len(getUnmarked()) != 0:
    result.setIfSubscribed("_UNMARKED", getUnmarked())

  if len(cachedSearchPath) != 0:
    result.setIfSubscribed("_OP_SEARCH_PATH", cachedSearchPath)

  result.setIfSubscribed("_OPERATION", getBaseCommandName())
  result.setIfSubscribed("_OP_CHALKER_VERSION", getChalkExeVersion())
  result.setIfSubscribed("_OP_PLATFORM", getChalkPlatform())
  result.setIfSubscribed("_OP_CHALKER_COMMIT_ID", getChalkCommitId())
  result.setIfSubscribed("_OP_CHALK_COUNT", len(getAllChalks()) -
                                         len(getUnmarked()))
  result.setIfSubscribed("_OP_EXE_NAME", getMyAppPath())
  result.setIfSubscribed("_OP_EXE_PATH", getAppDir())
  result.setIfSubscribed("_OP_ARGV", @[getMyAppPath()] &
                                          commandLineParams())
  result.setIfSubscribed("_OP_HOSTNAME", getHostName())
  result.setIfSubscribed("_OP_UNMARKED_COUNT", len(getUnmarked()))
  result.setIfSubscribed("_TIMESTAMP", pack(uint64(instant * 1000.0)))
  result.setIfSubscribed("_DATE", pack(getDate()))
  result.setIfSubscribed("_TIME", pack(getTime()))
  result.setIfSubscribed("_TZ_OFFSET", pack(getOffset()))
  result.setIfSubscribed("_DATETIME", pack(getDateTime()))

  if isSubscribedKey("_ENV"):
    result["_ENV"] = getEnvDict()

  if isSubscribedKey("_OP_HOST_REPORT_KEYS") and
     getOutputConfig().hostReport != "":
    let
      profile    = chalkConfig.profiles[getOutputConfig().hostReport]
      reportKeys = toSeq(hostInfo.filterByProfile(profile).keys)

    result["_OP_HOST_REPORT_KEYS"] = pack(reportKeys)

  when defined(posix):
    result.setIfSubscribed("_OP_HOSTINFO", uinfo.version)
    result.setIfSubscribed("_OP_NODENAME", uinfo.nodename)

method getChalkTimeHostInfo*(self: SystemPlugin, p: seq[string]): ChalkDict =
  result           = ChalkDict()
  cachedSearchPath = p

  result.setIfSubscribed("INJECTOR_VERSION", getChalkExeVersion())
  result.setIfSubscribed("INJECTOR_PLATFORM", getChalkPlatform())
  result.setIfSubscribed("INJECTOR_COMMIT_ID", getChalkCommitId())
  result.setIfSubscribed("DATE", pack(getDate()))
  result.setIfSubscribed("TIME", pack(getTime()))
  result.setIfSubscribed("TZ_OFFSET", pack(getOffset()))
  result.setIfSubscribed("DATETIME", pack(getDateTime()))
  result.setIfSubscribed("ENV", getEnvDict())

  when defined(posix):
    result.setIfSubscribed("INSERTION_HOSTINFO", uinfo.version)
    result.setIfSubscribed("INSERTION_NODENAME", uinfo.nodename)

  if isSubscribedKey("INJECTOR_ID"):
    let selfIdOpt = selfID
    if selfIdOpt.isSome(): result["INJECTOR_ID"] = pack(selfIdOpt.get())

proc signingNotInMark(): bool =
  let outConf = getOutputConfig()

  if outConf.chalk == "":
    return true
  let prof = chalkConfig.profiles[outConf.chalk]

  if "SIGNING" notin prof.keys:
    return true

  return not prof.keys["SIGNING"].report

method getChalkTimeArtifactInfo*(self: MetsysPlugin, obj: ChalkObj): ChalkDict =
  result = ChalkDict()

  if obj.extract != nil and "$CHALK_CONFIG" in obj.extract and
     "$CHALK_CONFIG" notin obj.collectedData:
    result["$CHALK_CONFIG"] = obj.extract["$CHALK_CONFIG"]

  let shouldSign = isSubscribedKey("SIGNATURE")

  # We add these directly into collectedData so that it can get
  # added to the MD hash when we call normalizeChalk()
  if len(obj.err) != 0:
    obj.collectedData["ERR_INFO"] = pack(obj.err)

  if shouldSign:
    obj.collectedData["SIGNING"] = pack(true)
    if signingNotInMark():
      once:
        info("`SIGNING` must be configured for the chalk mark report " &
             "whenever SIGNATURE is configured. Forcing it on.")

  let
    toHash   = obj.getChalkMark().normalizeChalk()
    mdHash   = $(toHash.computeSHA256())
    encHash  = hashFmt(mdHash)
    outconf  = getOutputConfig()


  result["METADATA_HASH"] = pack(encHash)
  result["METADATA_ID"]   = pack(idFormat(mdHash))

  if not shouldSign:
    trace("SIGNATURE not configured.")
    return

  let
    hashOpt = obj.myCodec.getUnchalkedHash(obj)

  if hashOpt.isSome():
    let
      toSign  = @[pack(hashFmt(hashOpt.get()) & "\n" & encHash & "\n")]
      sigOpt  = runCallback(signSig, toSign)

    if sigOpt.isSome():
      let
        res  = sigOpt.get()
        tup  = unpack[seq[Box]](res)
        hash = unpack[string](tup[0])

      if hash != "":
        result["SIGNATURE"]   = tup[0]
        result["SIGN_PARAMS"] = tup[1]
    else:
      trace("No implementation of sign() provided; cannot sign.")
  else:
    trace("No hash available for this artifact at time of signing.")

registerPlugin("system", SystemPlugin())
registerPlugin("metsys", MetsysPlugin())
