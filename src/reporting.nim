##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk reporting logic.

import "."/[
  chalkjson,
  collect,
  config,
  object_store/api,
  reportcache,
  run_management,
  sinks,
  types,
]

proc topicSubscribe*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone():
    error(config & ": unknown sink configuration while subscribing for topic " & topic)
    return some(pack(false))

  let record = `rec?`.get()
  if not record.enabled:
    warn(config & ": sink is not enabled and cannot be subscribed for topic " & topic)
    return some(pack(false))

  let `topic?` = subscribe(topic, record)
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

proc setPerChalkReports(tmpl: string, key: string, chalks: seq[ChalkObj]) =
  var reports = seq[Box](@[])

  for chalk in chalks:
    if not chalk.isMarked() and len(chalk.collectedData) == 0:
      continue
    let oneReport = objectifyByTemplate(
      chalk.collectedData.filterByTemplate(tmpl),
      chalk.objectsData,
      tmpl,
    )
    if len(oneReport) != 0:
      reports.add(pack(oneReport))

  if len(reports) != 0:
    hostInfo[key] = pack(reports)
    forceReportKeys([key])
  elif key in hostInfo:
    hostInfo.del(key)

proc buildHostReport*(tmpl: string): string =
  setPerChalkReports(tmpl, "_CHALKS",              getAllChalks())
  setPerChalkReports(tmpl, "_COLLECTED_ARTIFACTS", getAllArtifacts())
  return objectifyByTemplate(
    hostInfo.filterByTemplate(tmpl),
    objectsData,
    tmpl,
  ).toJson(tmpl)

proc buildHostReportForChalk(chalk: ChalkObj, tmpl: string): string =
  setPerChalkReports(tmpl, "_CHALKS",              @[chalk])
  setPerChalkReports(tmpl, "_COLLECTED_ARTIFACTS", getAllArtifacts())
  return objectifyByTemplate(
    hostInfo.filterByTemplate(tmpl),
    objectsData,
    tmpl,
  ).toJson(tmpl)

proc doCommandReport(topic: string) =
  let
    unmarked       = getUnmarked()
    reportTemplate = getReportTemplate()

  trace(reportTemplate & ": Generating command report.")
  if len(unmarked) != 0:
    hostInfo["_UNMARKED"] = pack(unmarked)

  if getPerChalkReports():
    for chalk in getAllChalks():
      let report = buildHostReportForChalk(chalk, reportTemplate)
      if report != "":
        safePublish(topic, report)
  else:
    let report = buildHostReport(reportTemplate)
    if report != "":
      safePublish(topic, report)

proc doEmbeddedReport(): Box =
  let
    unmarked       = getUnmarked()
    reportTemplate = getReportTemplate()

  setPerChalkReports(reportTemplate, "_CHALKS",              getAllChalks())
  setPerChalkReports(reportTemplate, "_COLLECTED_ARTIFACTS", getAllArtifacts())

  if len(unmarked) != 0:
    hostInfo["_UNMARKED"] = pack(unmarked)
  else:
    if "_UNMARKED" in hostInfo:
      hostInfo.del("_UNMARKED")

  if "_CHALKS" in hostInfo:
    hostInfo["_CHALKS"]
  else:
    pack[seq[Box]](@[])

proc doCustomReporting() =
  for topic in getChalkSubsections("custom_report"):
    trace(topic & ": checking custom report")
    let spec = "custom_report." & topic
    let enabledOpt = attrGetOpt[bool](spec & ".enabled")
    if enabledOpt.isNone() or not enabledOpt.get(): continue
    var
      sinkConfs = attrGet[seq[string]](spec & ".sink_configs")

    discard registerTopic(topic)

    let
      commandName = getBaseCommandName()
      useWhen     = attrGet[seq[string]](spec & ".use_when")
    if commandName notin useWhen and "*" notin useWhen:
      trace(spec & ": skipping as " & commandName & " not in " & $useWhen)
      continue
    if topic == "audit" and not attrGet[bool]("publish_audit"):
      continue
    if len(sinkConfs) == 0 and topic notin ["audit", "chalk_usage_stats"]:
      warn("Report '" & topic & "' has no configured sinks.  Skipping.")

    let templateToUse  = getReportTemplate(spec)

    for sinkConfName in sinkConfs:
      let res = topicSubscribe((@[pack(topic), pack(sinkConfName)])).get()
      if not unpack[bool](res):
        warn("Report '" & topic & "' sink config is invalid. Skipping.")

    trace(topic & ": generating custom report")
    let perChalk = attrGetOpt[bool](spec & ".per_chalk").get(false)
    if perChalk:
      for chalk in getAllChalks():
        let report = buildHostReportForChalk(chalk, templateToUse)
        if report != "":
          safePublish(topic, report)
    else:
      let report = buildHostReport(templateToUse)
      if report != "":
        safePublish(topic, report)

proc doReporting*(topic="report", clearState = false) {.exportc, cdecl.} =
  if inSubscan():
    let ctx = getCurrentCollectionCtx()
    ctx.report = doEmbeddedReport()
  else:
    let
      skipCommand = attrGet[bool]("skip_command_report")
      skipCustom  = attrGet[bool]("skip_custom_reports")
    if skipCommand and skipCustom:
      return
    collectRunTimeHostInfo()
    if skipCommand:
      info("Skipping the command report as per the `skip_command_report` directive")
    else:
      doCommandReport(topic)
    if not skipCustom:
      doCustomReporting()
    writeReportCache()
  if clearState:
    clearReportingState()
