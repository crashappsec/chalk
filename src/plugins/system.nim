## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import nativesockets, nimSHA2, sequtils, times, ../config, ../plugin_api,
       ../normalize, ../chalkjson, ../selfextract

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
    return
  elif "CHALK_ID" notin fields:
    error(obj.name & ": extracted chalk mark missing CHALK_ID field")
    return
  elif obj.myCodec.getChalkID(obj) != unpack[string](fields["CHALK_ID"]):
    error(obj.name & ": extracted CHALK_ID doesn't match computed CHALK_ID")
    error(obj.myCodec.getChalkID(obj) & " vs: " &
      unpack[string](fields["CHALK_ID"]))
    return
  elif "METADATA_HASH" notin fields:
    error(obj.name & ": extracted chalk mark missing METADATA_HASH field")
    return
  var
    toHash   = fields.normalizeChalk()
    computed = hashFmt($(toHash.computeSHA256()))

  if computed != unpack[string](fields["METADATA_HASH"]):
    error(obj.name & ": extracted METADATA_HASH doesn't validate")

  elif "SIGNATURE" notin fields:
    if "SIGNING" in fields and unpack[bool](fields["SIGNING"]):
      error(obj.name & ": SIGNING was set, but SIGNATURE was not found")
  else:
    let artHash = obj.myCodec.getUnchalkedHash(obj)

    if artHash.isSome():
      let
        toVerify = pack(artHash.get() & "\n" & computed & "\n")
        args     = @[toVerify, fields["SIGNATURE"]]
        optValid = runCallback(verifySig, args)

      if optValid.isSome():
        result = unpack[bool](optValid.get())
        if not result:
          error(obj.name & ": signature verification failed.")
        else:
          info(obj.name & ": signature successfully verified.")
          return true
      else:
        once(warn(obj.name & ": no signature validation routine provided."))

# Even if you don't subscribe to TIMESTAMP_WHEN_CHALKED we collect it in case
# you're subscribed to something that uses it in a substitution.
method getChalkTimeArtifactInfo*(self: SystemPlugin, obj: ChalkObj): ChalkDict =
  result                           = ChalkDict()
  result["MAGIC"]                  = pack(magicUTF8)
  result["TIMESTAMP_WHEN_CHALKED"] = pack(unixTimeInMS())

  if obj.isMarked() and "METADATA_HASH" in obj.extract:
    let h = unpack[string](obj.extract["METADATA_HASH"]).strip().parseHexStr()

    result.setIfNeeded("OLD_CHALK_METADATA_HASH",
                           obj.extract["METADATA_HASH"])

    result.setIfNeeded("OLD_CHALK_METADATA_ID", idFormat(h))

proc applySubstitutions(obj: ChalkObj) {.inline.} =
  # Apply {}-style substitutions to artifact chalking keys where appropriate.
  let
    `cid?`    = obj.lookupCollectedKey("CHALK_ID")
    `ts?`     = obj.lookupCollectedKey("TIMESTAMP_WHEN_CHALKED")
    `path?`   = obj.lookupCollectedKey("PATH_WHEN_CHALKED")
    `hash?`   = obj.lookupCollectedKey("HASH")
    `tenant?` = obj.lookupCollectedKey("TENANT_ID_WHEN_CHALKED")
    `random?` = obj.lookupCollectedKey("CHALK_RAND")
  var
    subs: seq[(string, string)] = @[]

  if `cid?`.isSome():    subs.add(("{chalk_id}", unpack[string](`cid?`.get())))
  if `ts?`.isSome():     subs.add(("{now}", $(unpack[int](`ts?`.get()))))
  if `path?`.isSome():   subs.add(("{path}", unpack[string](`path?`.get())))
  if `tenant?`.isSome(): subs.add(("{tenant}", unpack[string](`tenant?`.get())))
  if `random?`.isSome(): subs.add(("{random}", unpack[string](`random?`.get())))
  if `hash?`.isSome():   subs.add(("{hash}", unpack[string](`hash?`.get())))

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

  if isChalkingOp():
    obj.applySubstitutions()
    if obj.isMarked():
      discard obj.validateMetadata()
    result.setIfNeeded("_OP_CHALKED_KEYS", toSeq(obj.getChalkMark().keys))
    result.setIfNeeded("_VIRTUAL", chalkConfig.getVirtualChalk())
  else:
    obj.opFailed = obj.validateMetadata()
    #result.setIfNeeded("_VALIDATED",  obj.opFailed)
    if obj.fsRef != "":
      result.setIfNeeded("_OP_ARTIFACT_PATH", resolvePath(obj.fsRef))

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
    result.setIfNeeded("_OP_ERRORS", systemErrors)

  if len(getUnmarked()) != 0:
    result.setIfNeeded("_UNMARKED", getUnmarked())

  if len(cachedSearchPath) != 0:
    result.setIfNeeded("_OP_SEARCH_PATH", cachedSearchPath)

  result.setIfNeeded("_OPERATION", getBaseCommandName())
  result.setIfNeeded("_OP_CHALKER_VERSION", getChalkExeVersion())
  result.setIfNeeded("_OP_PLATFORM", getChalkPlatform())
  result.setIfNeeded("_OP_CHALKER_COMMIT_ID", getChalkCommitId())
  result.setIfNeeded("_OP_CHALK_COUNT", len(getAllChalks()) -
                                         len(getUnmarked()))
  result.setIfNeeded("_OP_EXE_NAME", getMyAppPath())
  result.setIfNeeded("_OP_EXE_PATH", getAppDir())
  result.setIfNeeded("_OP_ARGV", @[getMyAppPath()] &
                                          commandLineParams())
  result.setIfNeeded("_OP_HOSTNAME", getHostName())
  result.setIfNeeded("_OP_UNMARKED_COUNT", len(getUnmarked()))
  result.setIfNeeded("_TIMESTAMP", pack(uint64(instant * 1000.0)))
  result.setIfNeeded("_DATE", pack(getDate()))
  result.setIfNeeded("_TIME", pack(getTime()))
  result.setIfNeeded("_TZ_OFFSET", pack(getOffset()))
  result.setIfNeeded("_DATETIME", pack(getDateTime()))

  if isSubscribedKey("_ENV"):
    result["_ENV"] = getEnvDict()

  if isSubscribedKey("_OP_HOST_REPORT_KEYS") and
     getOutputConfig().hostReport != "":
    let
      profile    = chalkConfig.profiles[getOutputConfig().hostReport]
      reportKeys = toSeq(hostInfo.filterByProfile(profile).keys)

    result["_OP_HOST_REPORT_KEYS"] = pack(reportKeys)

  when defined(posix):
    result.setIfNeeded("_OP_HOSTINFO", uinfo.version)
    result.setIfNeeded("_OP_NODENAME", uinfo.nodename)

method getChalkTimeHostInfo*(self: SystemPlugin): ChalkDict =
  result           = ChalkDict()
  cachedSearchPath = getContextDirectories()

  let pubKeyOpt = selfChalkGetKey("$CHALK_PUBLIC_KEY")
  if pubKeyOpt.isSome():
    result["INJECTOR_PUBLIC_KEY"] = pubKeyOpt.get()
  result.setIfNeeded("INJECTOR_VERSION", getChalkExeVersion())
  result.setIfNeeded("INJECTOR_COMMIT_ID", getChalkCommitId())
  result.setIfNeeded("INJECTOR_ENV", getEnvDict())
  result.setIfNeeded("DATE_CHALKED", pack(getDate()))
  result.setIfNeeded("TIME_CHALKED", pack(getTime()))
  result.setIfNeeded("TZ_OFFSET_WHEN_CHALKED", pack(getOffset()))
  result.setIfNeeded("DATETIME_WHEN_CHALKED", pack(getDateTime()))
  result.setIfNeeded("PLATFORM_WHEN_CHALKED", getChalkPlatform())

  when defined(posix):
    result.setIfNeeded("HOSTINFO_WHEN_CHALKED", uinfo.version)
    result.setIfNeeded("NODENAME_WHEN_CHALKED", uinfo.nodename)

  if isSubscribedKey("INJECTOR_CHALK_ID"):
    let selfIdOpt = selfID
    if selfIdOpt.isSome(): result["INJECTOR_CHALK_ID"] = pack(selfIdOpt.get())

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

  # Container signing happens in the attestation layer;
  # this will likely move there too.
  let shouldSign = isSubscribedKey("SIGNATURE") and getCommandName() == "insert"

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
    else:
      trace("No implementation of sign() provided; cannot sign.")
  else:
    trace("No hash available for this artifact at time of signing.")

registerPlugin("system", SystemPlugin())
registerPlugin("metsys", MetsysPlugin())
