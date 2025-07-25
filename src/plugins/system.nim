##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.

when defined(posix):
  import std/posix_utils

import std/[
  nativesockets,
  sequtils,
]
import ".."/[
  attestation_api,
  chalkjson,
  config,
  normalize,
  plugin_api,
  run_management,
  types,
  utils/envvars,
  utils/exec,
  utils/files,
  utils/times,
]

var execId = secureRand[uint64]().toHex().toLower()

proc recordExternalActions(kind: string, details: string) =
  externalActions.add(@[kind, details])

setExternalActionCallback(recordExternalActions)

proc validateMetaData*(obj: ChalkObj): ValidateResult {.cdecl, exportc.} =
  let fields = obj.extract

  # sanity checks
  if fields == nil or len(fields) == 0:
    return vBadMd
  elif "CHALK_ID" notin fields:
    error(obj.name & ": extracted chalk mark missing CHALK_ID field")
    return vBadMd
  elif obj.callGetChalkId() != unpack[string](fields["CHALK_ID"]):
    error(obj.name & ": extracted CHALK_ID doesn't match computed CHALK_ID")
    error(obj.callGetChalkId() & " vs: " & unpack[string](fields["CHALK_ID"]))
    return vBadMd
  elif "METADATA_ID" notin fields:
    error(obj.name & ": extracted chalk mark missing METADATA_ID field")
    return vBadMd

  let
    toHash       = fields.normalizeChalk()
    computed     = toHash.sha256()
    computedHash = computed.hex()
    computedId   = computed.idFormat()

  # metadata id is derived from metadata hash
  # so we validate it by recomputing it from full hash
  trace("computed = " & computedId)
  trace("mdid     = " & unpack[string](fields["METADATA_ID"]))
  if computedId != unpack[string](fields["METADATA_ID"]):
    error(obj.name & ": extracted METADATA_ID doesn't validate")
    return vBadMd

  if "METADATA_HASH" in fields:
    trace("computed = " & computedHash)
    trace("mdhash   = " & unpack[string](fields["METADATA_HASH"]))
    if computedHash != unpack[string](fields["METADATA_HASH"]):
      error(obj.name & ": extracted METADATA_HASH doesn't validate")
      return vBadMd

  try:
    if obj.canVerifyByHash():
      return obj.verifyByHash(computedHash)
    if obj.canVerifyBySigStore():
      let (isValid, _) = obj.verifyBySigStore()
      return isValid
  except:
    error("could not successfully validate signature due to: " & getCurrentExceptionMsg())
    return vNoCosign

# Even if you don't subscribe to TIMESTAMP_WHEN_CHALKED we collect it in case
# you're subscribed to something that uses it in a substitution.
proc sysGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                                        ChalkDict {.cdecl.} =
  result                           = ChalkDict()
  result["MAGIC"]                  = pack(magicUTF8)

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
    # Should have crashed by now if section does not exist :)
    if not attrGet[bool]("keyspec." & k & ".apply_substitutions"): continue
    let s = unpack[string](v)
    if not s.contains("{"): continue
    obj.collectedData[k] = pack(s.multiReplace(subs))

proc setValidated*(self: var ChalkDict, chalk: ChalkObj, valid: ValidateResult) =
  case valid
  of vOk:
    self.setIfNeeded("_VALIDATED_METADATA", true)
  of vSignedOk:
    self.setIfNeeded("_VALIDATED_METADATA", true)
    self.setIfNeeded("_VALIDATED_SIGNATURE", true)
  of vBadMd:
    self.setIfNeeded("_VALIDATED_METADATA", false)
    chalk.opFailed = true
  of vNoPk, vNoCosign, vNoHash:
    self.setIfNeeded("_VALIDATED_METADATA", true)
    self.setIfNeeded("_VALIDATED_SIGNATURE", false)
  of vBadSig:
    self.setIfNeeded("_VALIDATED_METADATA", true)
    self.setIfNeeded("_INVALID_SIGNATURE", true)

proc sysGetRunTimeArtifactInfo*(self: Plugin, obj: ChalkObj, insert: bool):
                              ChalkDict {.cdecl.} =
  result = ChalkDict()

  if insert:
    obj.applySubstitutions()
    let chalkedKeys = toSeq(obj.getChalkMark().keys)
    result.setIfNeeded("_OP_CHALKED_KEYS", chalkedKeys)
    result.setIfNeeded("_VIRTUAL", attrGet[bool]("virtual_chalk"))

  else:
    result.setValidated(obj, obj.validateMetaData())

  if obj.fsRef != "":
    result.setIfNeeded("_OP_ARTIFACT_PATH", resolvePath(obj.fsRef))
  result.setIfNeeded("_OP_ARTIFACT_ENV_VAR_NAME", obj.envVarName)
  result.setIfNeeded("_OP_ARTIFACT_ACCESSED", obj.accessed)

  let
    tmpl       = getReportTemplate()
    hostKeys   = hostInfo.filterByTemplate(tmpl)
    artKeys    = obj.collectedData.filterByTemplate(tmpl)
    reportKeys = toSeq(hostKeys.keys()) & toSeq(artKeys.keys())
  result.setIfNeeded("_OP_ARTIFACT_REPORT_KEYS", reportKeys)


var
  envdict          = Con4mDict[string, string]()
  cachedSearchPath = newSeq[string]()

proc clearCallback(self: Plugin) {.cdecl.} =
  envdict          = Con4mDict[string, string]()
  cachedSearchPath = @[]

when defined(posix):
  let uinfo = uname()

proc getEnvDict(): Box =
  if len(envdict) == 0:
    envdict = Con4mDict[string, string]()
    let
      always = attrGet[seq[string]]("env_always_show")
      never  = attrGet[seq[string]]("env_never_show")
      redact = attrGet[seq[string]]("env_redact")
      def    = attrGet[string]("env_default_action")[0]

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

  if len(getUnmarked()) != 0:
    result.setIfNeeded("_UNMARKED", getUnmarked())

  if len(cachedSearchPath) != 0:
    result.setIfNeeded("_OP_SEARCH_PATH", cachedSearchPath)

  var chalks = 0
  for i in objs:
    if i.isMarked():
      chalks += 1
  result.setIfNeeded("_OPERATION",            getBaseCommandName())
  result.setIfNeeded("_EXEC_ID",              execId)
  result.setIfNeeded("_OP_CHALKER_VERSION",   getChalkExeVersion())
  result.setIfNeeded("_OP_PLATFORM",          getChalkPlatform())
  result.setIfNeeded("_OP_CHALKER_COMMIT_ID", getChalkCommitId())
  result.setIfNeeded("_OP_CHALK_COUNT",       chalks)
  result.setIfNeeded("_OP_EXE_NAME",          getMyAppPath().splitPath().tail)
  result.setIfNeeded("_OP_EXE_PATH",          getAppDir())
  result.setIfNeeded("_OP_ARGV",              @[getMyAppPath()] & commandLineParams())
  result.setIfNeeded("_OP_HOSTNAME",          getHostname())
  result.setIfNeeded("_OP_UNMARKED_COUNT",    len(getUnmarked()))
  result.setIfNeeded("_TIMESTAMP",            startTime.toUnixInMs())
  result.setIfNeeded("_DATE",                 startTime.forReport().format(timesDateFormat))
  result.setIfNeeded("_TIME",                 startTime.forReport().format(timesTimeFormat))
  result.setIfNeeded("_TZ_OFFSET",            startTime.forReport().format(timesTzFormat))
  result.setIfNeeded("_DATETIME",             startTime.forReport().format(timesIso8601Format))

  if isSubscribedKey("_ENV"):
    result["_ENV"] = getEnvDict()

  if isSubscribedKey("_OP_HOST_REPORT_KEYS"):
    let reportKeys = toSeq(hostInfo.filterByTemplate(getReportTemplate()).keys)
    result.setIfNeeded("_OP_HOST_REPORT_KEYS", reportKeys)

  when defined(posix):
    result.setIfNeeded("_OP_HOST_SYSNAME", uinfo.sysname)
    result.setIfNeeded("_OP_HOST_RELEASE", uinfo.release)
    result.setIfNeeded("_OP_HOST_VERSION", uinfo.version)
    result.setIfNeeded("_OP_HOST_NODENAME", uinfo.nodename)
    result.setIfNeeded("_OP_HOST_MACHINE", uinfo.machine)

proc sysGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  result           = ChalkDict()
  cachedSearchPath = getContextDirectories()

  let pubKeyOpt = selfChalkGetKey("$CHALK_PUBLIC_KEY")
  if pubKeyOpt.isSome():
    result["INJECTOR_PUBLIC_KEY"] = pubKeyOpt.get()
  result.setIfNeeded("INJECTOR_VERSION", getChalkExeVersion())
  result.setIfNeeded("INJECTOR_COMMIT_ID", getChalkCommitId())
  result.setIfNeeded("INJECTOR_ENV", getEnvDict())
  result.setIfNeeded("DATE_CHALKED", startTime.forReport().format(timesDateFormat))
  result.setIfNeeded("TIME_CHALKED", startTime.forReport().format(timesTimeFormat))
  result.setIfNeeded("TZ_OFFSET_WHEN_CHALKED", startTime.forReport().format(timesTzFormat))
  result.setIfNeeded("DATETIME_WHEN_CHALKED", startTime.forReport().format(timesIso8601Format))
  result.setIfNeeded("TIMESTAMP_WHEN_CHALKED", startTime.toUnixInMs())
  result.setIfNeeded("PLATFORM_WHEN_CHALKED", getChalkPlatform())
  result.setIfNeeded("PUBLIC_IPV4_ADDR_WHEN_CHALKED", pack(getMyIpV4Addr()))

  when defined(posix):
    result.setIfNeeded("HOST_SYSNAME_WHEN_CHALKED", uinfo.sysname)
    result.setIfNeeded("HOST_RELEASE_WHEN_CHALKED", uinfo.release)
    result.setIfNeeded("HOST_VERSION_WHEN_CHALKED", uinfo.version)
    result.setIfNeeded("HOST_NODENAME_WHEN_CHALKED", uinfo.nodename)
    result.setIfNeeded("HOST_MACHINE_WHEN_CHALKED", uinfo.machine)

  if isSubscribedKey("INJECTOR_CHALK_ID"):
    let selfIdOpt = selfId
    if selfIdOpt.isSome(): result["INJECTOR_CHALK_ID"] = pack(selfIdOpt.get())

proc attestationGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                          ChalkDict {.cdecl.} =
  result = ChalkDict()

  # We add these directly into collectedData so that it can get
  # added to the MD hash when we call normalizeChalk()
  obj.collectedData.setIfNeeded("ERR_INFO", obj.err)
  obj.collectedData.setIfNeeded("FAILED_KEYS", obj.failedKeys)

  result.merge(obj.computeMetadataHashAndId())

  if obj.willSignByHash():
    try:
      result.update(obj.signByHash(unpack[string](result["METADATA_HASH"])))
    except:
      error("Cannot sign " & obj.name & ": " & getCurrentExceptionMsg())

proc attestationGetRunTimeArtifactInfo(self: Plugin, obj: ChalkObj, insert: bool):
                                       ChalkDict {.cdecl.} =
  result = ChalkDict()
  if insert and obj.willSignBySigStore():
    try:
      result.update(obj.signBySigStore())
    except:
      error("Cannot sign " & obj.name & ": " & getCurrentExceptionMsg())

proc metsysGetRunTimeHostInfo(self: Plugin, objs: seq[ChalkObj]):
                              ChalkDict {.cdecl.} =
  result = ChalkDict()

  result.setIfNeeded("_OP_EXIT_CODE", getExitCode())
  result.setIfNeeded("_OP_ERRORS", systemErrors)
  result.setIfNeeded("_OP_FAILED_KEYS", failedKeys)
  result.setIfNeeded("_CHALK_EXTERNAL_ACTION_AUDIT", externalActions)

  if isSubscribedKey("_CHALK_RUN_TIME"):
    let
      monoEndTime = getMonoTime()
      diff        = monoEndTime - monoStartTime
      inMs        = diff.inMilliseconds()
    result["_CHALK_RUN_TIME"] = pack(inMs)

proc loadSystem*() =
  newPlugin("system",
            resourceTypes  = allResourceTypes,
            clearCallback  = PluginClearCb(clearCallback),
            ctHostCallback = ChalkTimeHostCb(sysGetChalkTimeHostInfo),
            ctArtCallback  = ChalkTimeArtifactCb(sysGetChalkTimeArtifactInfo),
            rtArtCallback  = RunTimeArtifactCb(sysGetRunTimeArtifactInfo),
            rtHostCallback = RunTimeHostCb(sysGetRunTimeHostInfo),
            isSystem       = true)

  newPlugin("attestation",
            resourceTypes  = allResourceTypes,
            ctArtCallback  = ChalkTimeArtifactCb(attestationGetChalkTimeArtifactInfo),
            rtArtCallback  = RunTimeArtifactCb(attestationGetRunTimeArtifactInfo),
            isSystem       = true)

  newPlugin("metsys",
            resourceTypes  = allResourceTypes,
            rtHostCallback = RunTimeHostCb(metsysGetRunTimeHostInfo),
            isSystem       = true)
