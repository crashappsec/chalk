##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk reporting logic.

import config, chalkjson, reportcache, sinks, collect

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

proc setPerChalkReports(tmpl: ReportTemplate) =
  ## Adds the `_CHALKS` key in the `hostinfo` global to the current
  ## collection context with whatever items were requested in the
  ## reporting template passed.
  var
    reports = seq[Box](@[])

  for chalk in getAllChalks():
    if not chalk.isMarked() and len(chalk.collectedData) == 0:
      continue
    let oneReport = chalk.collectedData.filterByTemplate(tmpl)

    if len(oneReport) != 0:
      reports.add(pack(oneReport))

  if len(reports) != 0:
    hostInfo["_CHALKS"] = pack(reports)
    forceReportKeys(["_CHALKS"])
  elif "_CHALKS" in hostInfo:
    hostInfo.del("_CHALKS")

template buildHostReport*(tmpl: ReportTemplate): string =
  setPerChalkReports(tmpl)
  prepareContents(hostInfo, tmpl)

proc doCommandReport(): string {.inline.} =
  let
    unmarked       = getUnmarked()
    reportTemplate = getReportTemplate()
    # The above goes from the string name to the object.

  if chalkConfig.getSkipCommandReport():
    info("Skipping the command report as per the `skip_command_report` directive")
    result = ""
  else:
    if len(unmarked) != 0:
      hostInfo["_UNMARKED"] = pack(unmarked)

    result = buildHostReport(reportTemplate)

template doEmbeddedReport(): Box =
  let
    unmarked       = getUnmarked()
    reportTemplate = getReportTemplate()

  setPerChalkReports(reportTemplate)

  if len(unmarked) != 0:
    hostInfo["_UNMARKED"] = pack(unmarked)
  else:
    if "_UNMARKED" in hostInfo:
      hostInfo.del("_UNMARKED")

  if "_CHALKS" in hostInfo:
    hostInfo["_CHALKS"]
  else:
    pack[seq[Box]](@[])

template doCustomReporting() =
  for topic, spec in chalkConfig.reportSpecs:
    if not spec.enabled: continue
    var
      sinkConfs = spec.sinkConfigs

    discard registerTopic(topic)

    if getCommandName() notin spec.useWhen and "*" notin spec.useWhen:
      continue
    if topic == "audit" and not chalkConfig.getPublishAudit():
      continue
    if len(sinkConfs) == 0 and topic notin ["audit", "chalk_usage_stats"]:
      warn("Report '" & topic & "' has no configured sinks.  Skipping.")

    let templateToUse = chalkConfig.reportTemplates[spec.reportTemplate]

    for sinkConfName in sinkConfs:
      let res = topicSubscribe((@[pack(topic), pack(sinkConfName)])).get()
      if not unpack[bool](res):
        warn("Report '" & topic & "' sink config is invalid. Skipping.")

    safePublish(topic, buildHostReport(templateToUse))


proc doReporting*(topic="report") {.exportc, cdecl.} =
  if inSubscan():
    let ctx = getCurrentCollectionCtx()
    ctx.report = doEmbeddedReport()
  else:
    trace("Collecting runtime host info.")
    collectRunTimeHostInfo()
    trace("Generating command report.")
    let report = doCommandReport()
    if report != "":
      safePublish(topic, report)
    doCustomReporting()
    writeReportCache()
