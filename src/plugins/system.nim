##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.

import std/monotimes, nativesockets, sequtils, times, ../config,
       ../plugin_api, ../normalize, ../chalkjson, ../selfextract,
       ../attestation, ../util

when defined(posix): import posix_utils

var
  externalActions: seq[seq[string]] = @[]

proc recordExternalActions(kind: string, details: string) =
  externalActions.add(@[kind, details])

setExternalActionCallback(recordExternalActions)


proc validateMetadata*(obj: ChalkObj): ValidateResult {.cdecl, exportc.} =
  let fields = obj.extract

  # Re-compute the chalk ID.
  if fields == nil or len(fields) == 0:
    return
  elif "CHALK_ID" notin fields:
    error(obj.name & ": extracted chalk mark missing CHALK_ID field")
    return vBadMd
  elif obj.callGetChalkID() != unpack[string](fields["CHALK_ID"]):
    error(obj.name & ": extracted CHALK_ID doesn't match computed CHALK_ID")
    error(obj.callGetChalkID() & " vs: " &
      unpack[string](fields["CHALK_ID"]))
    return vBadMd
  var
    toHash   = fields.normalizeChalk()
    computed = toHash.sha256()

  if "METADATA_HASH" in fields:
    trace("computed = " & computed.hex())
    trace("mdhash   = " & unpack[string](fields["METADATA_HASH"]))
    if computed.hex() != unpack[string](fields["METADATA_HASH"]):
      error(obj.name & ": extracted METADATA_HASH doesn't validate")
      return vBadMd
  else:
    let computedMdId = computed.idFormat()
    trace("computed = " & computedMdId)
    trace("mdid     = " & unpack[string](fields["METADATA_ID"]))
    if computedMdId != unpack[string](fields["METADATA_ID"]):
      error(obj.name & ": extracted METADATA_ID doesn't validate")
      return vBadMd

  if obj.fsRef == "":
    # For containers, validation currently happens via cmd_docker.nim;
    # They could definitely come together.
    #
    # TODO: Probably should add a check here to make sure the codec is
    # on a list of ones that may not set fsRef.
    return vOk

  if "SIGNATURE" notin fields:
    if "SIGNING" in fields and unpack[bool](fields["SIGNING"]):
      error(obj.name & ": SIGNING was set, but SIGNATURE was not found")
      return vBadMd
    else:
      return vOk

  if "INJECTOR_PUBLIC_KEY" notin fields:
    error(obj.name & ": Bad chalk mark; signed, but missing INJECTOR_PUBLIC_KEY")
    return vNoPk

  if getCosignLocation() == "":
    warn(obj.name & ": Signed but cannot validate; run `chalk setup` to fix")
    return vNoCosign

  let artHash = obj.callGetUnchalkedHash()
  if artHash.isNone():
    return vNoHash

  let
    sig    = unpack[string](fields["SIGNATURE"])
    pubkey = unpack[string](fields["INJECTOR_PUBLIC_KEY"])

  result = obj.cosignNonContainerVerify(artHash.get(), computed.hex(), sig, pubkey)

# Even if you don't subscribe to TIMESTAMP_WHEN_CHALKED we collect it in case
# you're subscribed to something that uses it in a substitution.
proc sysGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                                        ChalkDict {.cdecl.} =
  result                           = ChalkDict()
  result["MAGIC"]                  = pack(magicUTF8)
  result["TIMESTAMP_WHEN_CHALKED"] = pack(unixTimeInMS())

  if isSubscribedKey("PRE_CHALK_HASH") and obj.fsRef != "":
    chalkUseStream(obj):
      result["PRE_CHALK_HASH"] = pack(obj.stream.readAll().sha256Hex())

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

proc sysGetRunTimeArtifactInfo*(self: Plugin, obj: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result = ChalkDict()

  if isChalkingOp():
    obj.applySubstitutions()
    result.setIfNeeded("_OP_CHALKED_KEYS", toSeq(obj.getChalkMark().keys))
    result.setIfNeeded("_VIRTUAL", chalkConfig.getVirtualChalk())
  else:
    case obj.validateMetaData()
    of vOk:
      result.setIfNeeded("_VALIDATED_METADATA", true)
    of vSignedOk:
      result.setIfNeeded("_VALIDATED_METADATA", true)
      result.setIfNeeded("_VALIDATED_SIGNATURE", true)
    of vBadMd:
      result.setIfNeeded("_VALIDATED_METADATA", false)
      obj.opFailed = true
    of vNoPk, vNoCosign, vNoHash:
      result.setIfNeeded("_VALIDATED_METADATA", true)
      result.setIfNeeded("_VALIDATED_SIGNATURE", false)
    of vBadSig:
      result.setIfNeeded("_VALIDATED_METADATA", true)
      result.setIfNeeded("_INVALID_SIGNATURE", true)

    if obj.fsRef != "":
      result.setIfNeeded("_OP_ARTIFACT_PATH", resolvePath(obj.fsRef))

  var
    config       = getOutputConfig()
    templateName = config.reportTemplate

  if templateName != "":
    let
      tmpl       = getReportTemplate()
      hostKeys   = hostInfo.filterByTemplate(tmpl)
      artKeys    = obj.collectedData.filterByTemplate(tmpl)
      reportKeys = toSeq(hostKeys.keys()) & toSeq(artKeys.keys())

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
      elif def == 'i':  continue
      elif def == 'r':  envdict[k] = "<<redact>>"
      else: envdict[k] = v

  return pack(envdict)

proc sysGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                          ChalkDict {.cdecl.} =
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
  result.setIfNeeded("_OP_EXE_NAME", getMyAppPath().splitPath().tail)
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
     getOutputConfig().reportTemplate != "":
    let
      templateName  = getOutputConfig().reportTemplate
      templateToUse = chalkConfig.reportTemplates[templateName]
      reportKeys    = toSeq(hostInfo.filterByTemplate(templateToUse).keys)

    result["_OP_HOST_REPORT_KEYS"] = pack(reportKeys)

  when defined(posix):
    result.setIfNeeded("_OP_HOSTINFO", uinfo.version)
    result.setIfNeeded("_OP_NODENAME", uinfo.nodename)

proc sysGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
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
  result.setIfNeeded("PUBLIC_IPV4_ADDR_WHEN_CHALKED", pack(getMyIpV4Addr()))

  when defined(posix):
    result.setIfNeeded("HOSTINFO_WHEN_CHALKED", uinfo.version)
    result.setIfNeeded("NODENAME_WHEN_CHALKED", uinfo.nodename)

  if isSubscribedKey("INJECTOR_CHALK_ID"):
    let selfIdOpt = selfID
    if selfIdOpt.isSome(): result["INJECTOR_CHALK_ID"] = pack(selfIdOpt.get())

proc metsysGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                     ChalkDict {.cdecl.} =
  result = ChalkDict()

  # We add these directly into collectedData so that it can get
  # added to the MD hash when we call normalizeChalk()
  if len(obj.err) != 0:
    obj.collectedData["ERR_INFO"] = pack(obj.err)

  let pubKey = obj.willSignNonContainer()
  if pubKey != "":
    obj.collectedData["SIGNING"]             = pack(true)
    obj.collectedData["INJECTOR_PUBLIC_KEY"] = pack(pubKey)
    forceChalkKeys(["SIGNING", "SIGNATURE", "INJECTOR_PUBLIC_KEY"])

  let
    toHash   = obj.getChalkMark().normalizeChalk()
    mdHash   = toHash.sha256()
    encHash  = mdHash.hex()

  result["METADATA_HASH"] = pack(encHash)
  result["METADATA_ID"]   = pack(idFormat(mdHash))

  if pubKey == "":
    return

  let
    hashOpt = obj.callGetUnchalkedHash()

  if not hashOpt.isSome():
    warn(obj.name &
      ": Cannot sign; No hash available for this artifact at time of signing.")
    return

  let sig = obj.signNonContainer(hashOpt.get(), encHash)

  if sig == "":
    warn(obj.name & ": Cannot sign; cosign command failed.")
    return

  result["SIGNATURE"] = pack(sig)

proc metsysGetRunTimeHostInfo(self: Plugin, objs: seq[ChalkObj]):
                             ChalkDict {.cdecl.} =
  result = ChalkDict()

  if len(externalActions) > 0:
    result.setIfNeeded("_CHALK_EXTERNAL_ACTION_AUDIT", externalActions)

  if isSubscribedKey("_CHALK_RUN_TIME"):
    # startTime lives in runManagement.
    let
      diff = getMonoTime().ticks() - startTime
      inMs = diff div 1000 # It's in nanosec, convert to 1/1000000th of a sec


    result["_CHALK_RUN_TIME"] = pack(inMs)

proc loadSystem*() =
  newPlugin("system",
            ctHostCallback = ChalkTimeHostCb(sysGetChalkTimeHostInfo),
            ctArtCallback  = ChalkTimeArtifactCb(sysGetChalkTimeArtifactInfo),
            rtArtCallback  = RunTimeArtifactCb(sysGetRunTimeArtifactInfo),
            rtHostCallback = RunTimeHostCb(sysGetRunTimeHostInfo))

  newPlugin("metsys",
           ctArtCallback = ChalkTimeArtifactCb(metsysGetChalkTimeArtifactInfo),
           rtHostCallback = RunTimeHostCb(metsysGetRunTimeHostInfo))
