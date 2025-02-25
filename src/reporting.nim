##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk reporting logic.

import "."/[config, chalkjson, reportcache, sinks, collect]

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
    let oneReport = chalk.collectedData.filterByTemplate(tmpl)
    if len(oneReport) != 0:
      reports.add(pack(oneReport))

  if len(reports) != 0:
    hostInfo[key] = pack(reports)
    forceReportKeys([key])
  elif key in hostInfo:
    hostInfo.del(key)

proc setPerChalkReports(tmpl: string) =
  ## Adds the `_CHALKS` key in the `hostinfo` global to the current
  ## collection context with whatever items were requested in the
  ## reporting template passed.
  setPerChalkReports(tmpl, "_CHALKS",              getAllChalks())
  setPerChalkReports(tmpl, "_COLLECTED_ARTIFACTS", getAllArtifacts())

proc buildHostReport*(tmpl: string): string =
  setPerChalkReports(tmpl)
  prepareContents(hostInfo, tmpl)

proc doCommandReport(): string =
  let
    unmarked       = getUnmarked()
    reportTemplate = getReportTemplate()
    # The above goes from the string name to the object.

  if attrGet[bool]("skip_command_report"):
    info("Skipping the command report as per the `skip_command_report` directive")
    result = ""
  else:
    if len(unmarked) != 0:
      hostInfo["_UNMARKED"] = pack(unmarked)

    result = buildHostReport(reportTemplate)

proc doEmbeddedReport(): Box =
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

proc doCustomReporting() =
  for topic in getChalkSubsections("custom_report"):
    let spec = "custom_report." & topic
    let enabledOpt = attrGetOpt[bool](spec & ".enabled")
    if enabledOpt.isNone() or not enabledOpt.get(): continue
    var
      sinkConfs = attrGet[seq[string]](spec & ".sink_configs")

    discard registerTopic(topic)

    let useWhen = attrGet[seq[string]](spec & ".use_when")
    if getCommandName() notin useWhen and "*" notin useWhen:
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

    safePublish(topic, buildHostReport(templateToUse))

proc doReporting*(topic="report") {.exportc, cdecl.} =
  if inSubscan():
    let ctx = getCurrentCollectionCtx()
    ctx.report = doEmbeddedReport()
  else:
    let
      skipCommand = attrGet[bool]("skip_command_report")
      skipCustom  = attrGet[bool]("skip_custom_reports")
    if skipCommand and skipCustom:
      return
    trace("Collecting runtime host info.")
    collectRunTimeHostInfo()
    trace("Generating command report.")
    let report = doCommandReport()
    if report != "":
      safePublish(topic, report)
    if not skipCustom:
      doCustomReporting()
    writeReportCache()
