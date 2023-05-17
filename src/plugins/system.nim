## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, nativesockets, tables, options, strutils, nimSHA2, sequtils, times,
       ../config, ../plugins, ../normalize, ../chalkjson

when defined(posix): import posix_utils
when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

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

method getChalkInfo*(self: SystemPlugin, obj: ChalkObj): ChalkDict =
  result              = ChalkDict()
  result["MAGIC"]     = pack(magicUTF8)
  result["TIMESTAMP"] = pack(unixTimeInMS())

  if obj.isMarked() and "METADATA_HASH" in obj.extract:
    let h = unpack[string](obj.extract["METADATA_HASH"]).strip().parseHexStr()

    result["OLD_CHALK_METADATA_HASH"] = obj.extract["METADATA_HASH"]
    result["OLD_CHALK_METADATA_ID"]   = pack(idFormat(h))

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

method getPostChalkInfo*(self: SystemPlugin,
                         obj:  ChalkObj,
                         ins:  bool): ChalkDict =
  result = ChalkDict()

  if not ins:
    obj.opFailed                       = obj.validateMetadata()
    result["_VALIDATED"]               = pack(obj.opFailed)
    result["_OP_ARTIFACT_PATH"]        = pack(resolvePath(obj.fullPath))
  else:
    obj.applySubstitutions()
    if obj.isMarked(): discard obj.validateMetadata()
    result["_OP_CHALKED_KEYS"] = pack(toSeq(obj.getChalkMark().keys))
    result["_VIRTUAL"]         = pack(chalkConfig.getVirtualChalk())

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


let
  instant   = epochTime()
  timestamp = instant.fromUnixFloat()
  date      = timestamp.format("yyyy-MM-dd")
  time      = timestamp.format("HH:mm:ss") & "." & timestamp.format("fff")
  offset    = timestamp.format("zzz")

method getPostRunInfo*(self: SystemPlugin, objs: seq[ChalkObj]): ChalkDict =
  result = ChalkDict()

  if len(systemErrors)  != 0: result["_OP_ERRORS"] = pack(systemErrors)
  if len(getUnmarked()) != 0: result["_UNMARKED"]  = pack(getUnmarked())

  result["_OPERATION"]            = pack(getCommandName())
  result["_OP_CHALKER_VERSION"]   = pack(getChalkExeVersion())
  result["_OP_PLATFORM"]          = pack(getChalkPlatform())
  result["_OP_CHALKER_COMMIT_ID"] = pack(getChalkCommitId())
  result["_OP_CHALK_COUNT"]       = pack(len(getAllChalks()) -
                                         len(getUnmarked()))
  result["_OP_EXE_NAME"]          = pack(getAppFilename())
  result["_OP_EXE_PATH"]          = pack(getAppDir())
  result["_OP_ARGV"]              = pack(@[getAppFileName()] &
                                          commandLineParams())
  result["_OP_HOSTNAME"]          = pack(getHostName())
  result["_OP_UNMARKED_COUNT"]    = pack(len(getUnmarked()))
  result["_TIMESTAMP"]            = pack(uint64(instant * 1000.0))
  result["_DATE"]                 = pack(date)
  result["_TIME"]                 = pack(time)
  result["_TZ_OFFSET"]            = pack(offset)
  result["_DATETIME"]             = pack(date & "T" & time & offset)

  if getOutputConfig().hostReport != "":
    let
      profile    = chalkConfig.profiles[getOutputConfig().hostReport]
      reportKeys = toSeq(hostInfo.filterByProfile(profile).keys)

    result["_OP_HOST_REPORT_KEYS"] = pack(reportKeys)

  when defined(posix):
    let uinfo = uname()
    result["_OP_HOSTINFO"] = pack(uinfo.version)
    result["_OP_NODENAME"] = pack(uinfo.nodename)

proc buildEnvDict(): Con4mDict[string, string] =
  result = Con4mDict[string, string]()
  let
    always = chalkConfig.getEnvAlwaysShow()
    never  = chalkConfig.getEnvNeverShow()
    redact = chalkConfig.getEnvRedact()
    def    = chalkConfig.getEnvDefaultAction()[0]

  for (k, v) in envPairs():
    # TODO: could add some con4m to warn on overlap across these 3. For now,
    # we treat it conservatively.
    if k in never:    continue
    elif k in redact: result[k] = "<<redact>>"
    elif k in always: result[k] = v
    elif def == 'n':  continue
    elif def == 'r':  result[k] = "<<redact>>"
    else: result[k] = v

method getHostInfo*(self: SystemPlugin, p: seq[string], ins: bool): ChalkDict =
  result  = ChalkDict()
  var env = buildEnvDict()

  # We have thse info now, and it is harder to get later, so cheat a bit
  # by injecting it directly into hostInfo.  We're the only one who should
  # ever touch these keys anyway.
  hostInfo["_OP_SEARCH_PATH"] = pack(p)
  hostInfo["_ENV"]            = pack(env)

  if ins:
    result["INJECTOR_VERSION"]   = pack(getChalkExeVersion())
    result["INJECTOR_PLATFORM"]  = pack(getChalkPlatform())
    result["INJECTOR_COMMIT_ID"] = pack(getChalkCommitId())
    result["DATE"]               = pack(date)
    result["TIME"]               = pack(time)
    result["TZ_OFFSET"]          = pack(offset)
    result["DATETIME"]           = pack(date & "T" & time & offset)
    result["ENV"]                = pack(env)

    when defined(posix):
      let uinfo = uname()
      result["INSERTION_HOSTINFO"] = pack(uinfo.version)
      result["INSERTION_NODENAME"] = pack(uinfo.nodename)

    let selfIdOpt = selfID
    if selfIdOpt.isSome(): result["INJECTOR_ID"] = pack(selfIdOpt.get())

method getChalkInfo*(self: MetsysPlugin, obj: ChalkObj): ChalkDict =
  result = ChalkDict()

  # We add this one in directly so that it gets added to the MD hash.
  if len(obj.err) != 0:
    obj.collectedData["ERR_INFO"] = pack(obj.err)

  var shouldSign = false

  let
    toHash   = obj.getChalkMark().normalizeChalk()
    mdHash   = $(toHash.computeSHA256())
    encHash  = hashFmt(mdHash)
    outconf  = getOutputConfig()
    ckeys    = chalkConfig.profiles[outconf.chalk].getKeys()
    rkeys    = chalkConfig.profiles[outconf.artifactReport].getKeys()

  result["METADATA_HASH"] = pack(encHash)
  result["METADATA_ID"]   = pack(idFormat(mdHash))

  # Signing is expensive enough that we check to make sure signing is on.
  if "SIGNATURE" in ckeys and ckeys["SIGNATURE"].report:
    shouldSign = true
  else:
    trace("SIGNATURE not configured in chalking profile.")

  if "SIGNATURE" in rkeys and rkeys["SIGNATURE"].report:
    shouldSign = true
  else:
    trace("SIGNATURE is not configured in reporting profile.")

  if not shouldSign: return

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
