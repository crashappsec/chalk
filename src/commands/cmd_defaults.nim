## The `chalk defaults` command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import ../config, ../sinks, macros

proc paramFmt(t: StringTable): string =
  var parts: seq[string] = @[]

  for key, val in t:
    if key == "secret": parts.add(key & " : " & "(redacted)")
    else:               parts.add(key & " : " & val)

  return parts.join(", ")

proc filterFmt(flist: seq[MsgFilter]): string =
  var parts: seq[string] = @[]

  for filter in flist: parts.add(filter.getFilterName().get())

  return parts.join(", ")

proc getSinkConfigTable(): string =
  var
    sinkConfigs = getSinkConfigs()
    ot          = tableC4mStyle(5)
    subLists:     Table[SinkConfig, seq[string]]
    unusedTopics: seq[string]

  for topic, obj in allTopics:
    let subscribers = obj.getSubscribers()
    if subscribers.len() == 0: unusedTopics.add(topic)
    for config in subscribers:
      if config notin subLists: subLists[config] = @[topic]
      else:                     subLists[config].add(topic)

  ot.addRow(@["Config name", "Sink", "Parameters", "Filters", "Topics"])
  for key, config in sinkConfigs:
    if config notin sublists: sublists[config] = @[]
    ot.addRow(@[key,
                config.mySink.getName(),
                paramFmt(config.params),
                filterFmt(config.filters),
                sublists[config].join(", ")])

  let specs       = ot.getColSpecs()
  specs[2].minChr = 15

  result = ot.render()
  if len(unusedTopics) != 0 and getLogLevel() == llTrace:
    result &= formatTitle("Topics w/o subscriptions: " &
                          unusedTopics.join(", "))

proc showDisclaimer(w: int) {.inline.} =
  let disclaimer = chalkConfig.getDefaultsDisclaimer()
  publish("defaults", "\n" & indentWrap(disclaimer, w - 1) & "\n")

macro buildProfile(title: untyped, varName: untyped): untyped =
  return quote do:
    if outConf.`varName` != "":
      toPublish &= formatTitle(`title`)
      let
        oneProf = profs.contents[outConf.`varName`].get(AttrScope)
        keyArr  = oneProf.contents["key"].get(AttrScope)
      toPublish &= keyArr.arrayToTable(@["report"], @["Key Name", "Report?"])

proc showConfig*(force: bool = false) =
  once:
    const nope = "none\n\n"
    if not (chalkConfig.getPublishDefaults() or force): return
    let chalkRuntime = getChalkRuntime()
    var toPublish = ""
    let
      genCols  = @[fcFullName, fcShort, fcValue]
      genHdrs  = @["Conf variable", "Descrition", "Value"]
      outCols  = @[fcName, fcValue]
      outHdrs  = @["Report Type", "Profile"]
      ocCol    = @["chalk", "artifact_report", "host_report",
                   "invalid_chalk_report"]
      outconfs = if "outconf" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["outconf"].get(AttrScope)
                 else: nil
      crCol    = @["enabled", "artifact_report", "host_report",
                   "invalid_chalk_report", "use_when"]
      reports  = if "custom_report" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["custom_report"].get(AttrScope)
                 else: nil
      tCol     = @["kind", "enabled", "priority", "stop_on_success"]
      tools    = if "tool" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["tool"].get(AttrScope)
                 else: nil
      piCol    = @["codec", "enabled", "priority", "ignore", "overrides"]
      plugs    = if "plugin" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["plugin"].get(AttrScope)
                 else: nil
      profs    = if "profile" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["profile"].get(AttrScope)
                 else: nil

    if getCommandName() in outconfs.contents:
      let outc = outconfs.contents[getCommandName()].get(AttrScope)
      toPublish &= formatTitle("Loaded profiles")
      toPublish &= outc.oneObjToTable(outCols, outHdrs, "outconf")

      if getLogLevel() == llTrace:
        let outConf = getOutputConfig()

        buildProfile("Chalking Profile Settings", chalk)
        buildProfile("Artifact Report Settings", artifactReport)
        buildProfile("Host Report Settings", hostReport)
        buildProfile("Invalid Artifact Report Settings", invalidChalkReport)

    else:
      toPublish &= formatTitle("Output profiles")
      if outconfs != nil: toPublish &= outconfs.objectsToTable(ocCol)
      else:               toPublish &= nope

    toPublish &= formatTitle("Other reports")
    if reports != nil: toPublish &= reports.objectsToTable(crCol)
    else:              toPublish &= nope

    toPublish &= formatTitle("Installed Tools")
    if tools != nil: toPublish &= tools.objectsToTable(tcol)
    else:            toPublish &= nope

    toPublish &= formatTitle("Available Plugins")
    if plugs != nil: toPublish &= plugs.objectsToTable(piCol)
    else:            toPublish &= nope

    toPublish &= formatTitle("Sink Configurations")
    toPublish &= getSinkConfigTable()

    if getCommandName() == "defaults" and profs != nil:
      toPublish &= formatTitle("Available Profiles (see 'chalk profile NAME'" &
        "for details on a specific profile)")
      toPublish &= profs.listSections("Profile Name")

    toPublish &= formatTitle("General configuration")
    toPublish &= chalkRuntime.attrs.oneObjToTable(genCols, genHdrs)

    let dockerInfo = chalkConfig.dockerConfig.`@@attrscope@@`
    toPublish &= formatTitle("Docker configuration")
    toPublish &= dockerInfo.oneObjToTable(genCols, genHdrs, objType = "docker")

    let
      envInfo = chalkConfig.envConfig.`@@attrscope@@`
      toAdd   = envInfo.oneObjToTable(genCols, genHdrs, objType = "env_cache")

    if toAdd != "":
      toPublish &= formatTitle("Cached fields for env command") & toAdd

    publish("defaults", toPublish)
    if force: showDisclaimer(80)
