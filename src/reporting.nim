## Chalk reporting logic.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import config, chalkjson, reportcache, collect, sinks

let emptyReport               = toJson(ChalkDict())
var liftableKeys: seq[string] = @[]

proc topicSubscribe*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =

  if doingTestRun:
    return some(pack(true))

  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone():
    error(config & ": unknown sink configuration")
    return some(pack(false))

  let
    record   = `rec?`.get()
    `topic?` = subscribe(topic, record)

  if `topic?`.isNone():
    error(topic & ": unknown topic")
    return some(pack(false))

  return some(pack(true))

proc topicUnsubscribe*(args: seq[Box], unused: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone(): return some(pack(false))

  return some(pack(unsubscribe(topic, `rec?`.get())))

proc setPerChalkReports(successProfileName: string,
                        invalidProfileName: string,
                        hostProfileName:    string) =
  var
    reports     = seq[Box](@[])
    goodProfile = Profile(nil)
    badProfile  = Profile(nil)
    goodName    = successProfileName
    badName     = invalidProfileName
    hostProfile = chalkConfig.profiles[hostProfileName]

  if successProfileName != "" and successProfileName in chalkConfig.profiles:
    goodProfile = chalkConfig.profiles[successProfileName]

  if invalidProfileName != "" and invalidProfileName in chalkConfig.profiles:
    badProfile = chalkConfig.profiles[invalidProfileName]

  if goodProfile == nil or not goodProfile.enabled:
    goodProfile = badProfile
    goodName    = badName

  elif badProfile == nil or not badProfile.enabled:
    badProfile = goodProfile
    badName    = goodName

  if goodProfile == nil or not goodProfile.enabled: return

  # The below implements "lifting".  Lifting occurs when both a host
  # profile and artifact profile want to report on an artifact key.
  # The host report can only report it if the value is the same for
  # each artifact.  If it is, however, the intent is to NOT duplicate.
  # Therefore, what we do is explicitly turn off reporting at the
  # artifact level for any liftable key where the host profile is
  # going to report on it.
  #
  # However, we then need to turn those keys back on if we changed
  # them, because other custom reports this run may *only* ask for
  # something at the artifact level.  Therefore, we stash the key
  # objects, deleting them from the profile (absent means don't
  # report), and restore them at the end of the function.

  var
    goodStash: Table[string, KeyConfig]
    badStash:  Table[string, KeyConfig]

  if hostProfile != nil and hostProfile.enabled:
    for key in liftableKeys:
      if key notin hostProfile.keys or not hostProfile.keys[key].report:
        continue
      if key in goodProfile.keys and goodProfile.keys[key].report:
        goodStash[key] = goodProfile.keys[key]
        goodProfile.keys.del(key)
        trace("Lifting key '" & key & "' when host profile = '" &
          hostProfileName & "' and artifact profile = '" & goodName)
      if key in badProfile.keys and badProfile.keys[key].report:
        badStash[key] = badProfile.keys[key]
        badProfile.keys.del(key)
        trace("Lifting key '" & key & "' when host profile = '" &
          hostProfileName & "' and artifact profile = '" & badName)

  for chalk in getAllChalks():
    if not chalk.isMarked() and len(chalk.collectedData) == 0: continue
    let
      profile   = if not chalk.opFailed: goodProfile else: badProfile
      oneReport = hostInfo.filterByProfile(chalk.collectedData, profile)

    if len(oneReport) != 0: reports.add(pack(oneReport))

  # Now, reset any profiles where we performed lifting.
  for key, conf in goodStash: goodProfile.keys[key] = conf
  for key, conf in badStash:  badProfile.keys[key] = conf

  if len(reports) != 0:       hostInfo["_CHALKS"] = pack(reports)
  elif "_CHALKS" in hostInfo: hostInfo.del("_CHALKS")

proc doCommandReport(): string {.inline.} =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]
    unmarked    = getUnmarked()

  if (not hostProfile.enabled):
    warn("No host reporting profile enabled.")
    result = ""
  elif chalkConfig.getSkipCommandReport():
    info("Skipping the command report, because you said so.")
    result = ""
  else:
    setPerChalkReports(conf.artifactReport, conf.invalidChalkReport,
                       conf.hostReport)
    if len(unmarked) != 0: hostInfo["_UNMARKED"] = pack(unmarked)
    result = hostInfo.prepareContents(hostProfile)

template doEmbeddedReport(): Box =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]
    unmarked    = getUnmarked()

  if not hostProfile.enabled: pack("")
  else:
    setPerChalkReports(conf.artifactReport, conf.invalidChalkReport,
                       conf.hostReport)
    if "_CHALKS" in hostInfo:
      hostInfo["_CHALKS"]
    else:
      pack[seq[Box]](@[])

template doCustomReporting() =
  for topic, spec in chalkConfig.reportSpecs:
    if not spec.enabled: continue
    var
      sinkConfs = spec.sinkConfigs
      topicObj  = registerTopic(topic)

    if getCommandName() notin spec.useWhen and "*" notin spec.useWhen:
      continue
    if topic == "audit" and not chalkConfig.getPublishAudit():
      continue
    if len(sinkConfs) == 0 and topic notin ["audit", "chalk_usage_stats"]:
      warn("Report '" & topic & "' has no configured sinks.  Skipping.")

    for sinkConfName in sinkConfs:
      let res = topicSubscribe((@[pack(topic), pack(sinkConfName)])).get()
      if not unpack[bool](res):
        warn("Report '" & topic & "' sink config is invalid. Skipping.")

    setPerChalkReports(spec.artifactReport, spec.invalidChalkReport,
                       spec.hostReport)
    let profile = chalkConfig.profiles[spec.hostReport]
    if profile.enabled:
      safePublish(topic, hostInfo.prepareContents(profile))

proc liftUniformKeys() =
  let allChalks = getAllChalks()

  if len(allChalks) == 0: return

  var dictToUse: ChalkDict

  for key, spec in chalkConfig.keyspecs:
    # Host keys don't make sense to be lifted, so just skip.
    if spec.kind notin [int(KtChalk), int(KtNonChalk)]: continue
    var
      lift = true
      box: Option[Box] = none(Box)
    for chalk in allChalks:
      if getCommandName() in chalkConfig.getValidChalkCommandNames():
        dictToUse = chalk.collectedData
      else:
        dictToUse = chalk.extract

      if dictToUse == nil or key notin dictToUse:
        lift = false
        if key in hostInfo:
          liftableKeys.add(key)
          trace("Key  '" & key &
            "' was put in the host context by plugin and is liftable.")
        break
      if box.isNone():
        box = some(dictToUse[key])
      else:
        if dictToUse[key] != box.get():
          lift = false
          break
    if not lift:  continue

    for chalk in allChalks:
      if key in chalk.collectedData:
        chalk.collectedData.del(key)
    trace("Key '" & key & "' is liftable.")
    liftableKeys.add(key)
    hostInfo[key] = box.get()

proc doReporting*(topic="report") {.exportc,cdecl.} =
  if inSubscan():
    let ctx = getCurrentCollectionCtx()
    liftUniformKeys()
    ctx.report = doEmbeddedReport()
  else:
    trace("Collecting runtime host info.")
    collectRunTimeHostInfo()
    liftUniformKeys()
    trace("Generating command report.")
    let report = doCommandReport()
    if report != "":
      safePublish(topic, report)
    doCustomReporting()
    writeReportCache()
