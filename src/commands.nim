## This module implements both individual commands, and includes
## --publish-defaults functionality for other commands.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, unicode, os, streams
import config, builtins, collect, chalkjson, plugins, nimutils/help
import macros except error

# Helper to load profiles.
proc setPerChalkReports(successProfileName, invalidProfileName: string) =
  var
    reports     = seq[ChalkDict](@[])
    goodProfile = Profile(nil)
    badProfile  = Profile(nil)

  if successProfileName != "" and successProfileName in chalkConfig.profiles:
    goodProfile = chalkConfig.profiles[successProfileName]

  if invalidProfileName != "" and invalidProfileName in chalkConfig.profiles:
    badProfile = chalkConfig.profiles[invalidProfileName]

  if   goodProfile == nil or not goodProfile.enabled: goodProfile = badProfile
  elif badProfile  == nil or not  badProfile.enabled: badProfile = goodProfile

  if goodProfile == nil or not goodProfile.enabled: return

  for chalk in allChalks:
    let
      profile   = if not chalk.opFailed: goodProfile else: badProfile
      oneReport = hostInfo.filterByProfile(chalk.collectedData, profile)

    if len(oneReport) != 0: reports.add(oneReport)

  if len(reports) != 0:       hostInfo["_CHALKS"] = pack(reports)
  elif "_CHALKS" in hostInfo: hostInfo.del("_CHALKS")

# Next, our reporting.
template doCommandReport() =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]

  if not hostProfile.enabled: return

  setPerChalkReports(conf.artifactReport, conf.invalidChalkReport)
  if len(unmarked) != 0: hostInfo["_UNMARKED"] = pack(unmarked)
  publish("report", hostInfo.filterByProfile(hostProfile).toJson())

template doCustomReporting() =
  for topic, spec in chalkConfig.reportSpecs:
    if not spec.enabled: continue
    var
      sinkConfs = spec.sinkConfigs
      topicObj  = registerTopic(topic)

    if getCommandName() notin spec.use_when and "*" notin spec.useWhen:
      continue
    if topic == "audit" and not chalkConfig.getPublishAudit():
      continue
    if len(sinkConfs) == 0 and topic notin ["audit", "chalk_usage_stats"]:
      warn("Report '" & topic & "' has no configured sinks.  Skipping.")

    for sinkConfName in sinkConfs:
      let res = topicSubscribe((@[pack(topic), pack(sinkConfName)])).get()
      if not unpack[bool](res):
        warn("Report '" & topic & "' sink config is invalid. Skipping.")

    setPerChalkReports(spec.artifactProfile, spec.invalidChalkProfile)
    let profile = chalkConfig.profiles[spec.hostProfile]
    if profile.enabled:
      publish(topic, hostInfo.filterByProfile(profile).toJson())

proc doReporting() =
  collectPostRunInfo()
  doCommandReport()
  doCustomReporting()

proc runCmdExtract*() =
  initCollection()

  var numExtracts = 0
  for item in allArtifacts(): numExtracts += 1

  if numExtracts == 0: warn("No items extracted")
  doReporting()

proc runCmdInsert*() =
  initCollection()
  let virtual = chalkConfig.getVirtualChalk()

  for item in allArtifacts():
    trace(item.fullPath & ": begin chalking")
    item.collectChalkInfo()
    trace(item.fullPath & ": chalk data collection finished.")
    try:
      let
        toWrite = some(item.getChalkMark().toJson())
        rawHash = item.myCodec.handleWrite(item, toWrite, virtual)

      if virtual: info(item.fullPath & ": virtual chalk created")
      else:       info(item.fullPath & ": chalk mark successfully added")

      item.postHash = rawHash
    except:
      error(item.fullPath & ": insertion failed: " & getCurrentExceptionMsg())
      item.opFailed = true

  doReporting()

proc runCmdDelete*() =
  initCollection()

  for item in allArtifacts():
    if not item.isMarked():
      info(item.fullPath & ": no chalk mark to delete.")
      continue
    try:
      let rawHash = item.myCodec.handleWrite(item, none(string), false)

      info(item.fullPath & ": chalk mark successfully deleted")

      item.postHash = rawHash
    except:
      error(item.fullPath & ": deletion failed: " & getCurrentExceptionMsg())
      item.opFailed = true

  doReporting()

proc runCmdConfDump*() =
  var
    toDump  = defaultConfig
    argList = getArgs()
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = chalk.extract

  if chalk != nil and extract != nil and extract.contains("$CHALK_CONFIG"):
    toDump  = unpack[string](extract["$CHALK_CONFIG"])

  publish("confdump", toDump)

proc runCmdVersion*() =
  var
    rows = @[@["Chalk version", getChalkExeVersion()],
             @["Commit ID",     getChalkCommitID()],
             @["Build OS",      hostOS],
             @["Build CPU",     hostCPU],
             @["Build Date",    CompileDate],
             @["Build Time",    CompileTime & " UTC"]]
    t    = tableC4mStyle(2, rows=rows)

  t.setTableBorders(false)
  t.setNoHeaders()

  publish("version", t.render() & "\n")


proc formatTitle(text: string): string {.inline.} =
  let
    titleCode = toAnsiCode(@[acFont4, acBGreen])
    endCode   = toAnsiCode(@[acReset])

  return titleCode & text & endCode & "\n"

template row(x, y, z: string) = ot.addRow(@[x, y, z])

const helpPath   = staticExec("pwd") & "/help/"
const helpCorpus = newOrderedFileTable(helpPath)
proc transformKind(s: string): string =
  chalkConfig.getKtypeNames()[byte(s[0]) - 48]
proc fChalk(s: seq[string]): bool =
  if s[1].startsWith("Chalk") : return true
proc fHost(s: seq[string]): bool =
  if s[1].contains("Host"): return true
proc fArtifact(s: seq[string]): bool =
  if s[1].endsWith("Chalk") : return true
proc fReport(s: seq[string]): bool =
  if s[1] != "Chalk": return true

template restAreSearch() =
  if len(args) > 1 and args[1].toLowerAscii() in ["s", "search"]:
    search = args[2 .. ^1]
  else:
    search = args[1 .. ^1]

template handleObjTypeHelp(name: string) =
    if len(args) == 0:
      output = formatTitle("'" & name & "' Objects")
      output &= ctxChalkConf.getSectionDocStr(name).get()
      output &= "\n"
      output &= "See 'chalk help " & name
      output &= " props' for info on the key properties for " & name
      output &= " objects\n"
    else:
      if len(args) > 1:
        warn("'chalk help " & name & "' either takes 0 args, 'props' / 'p'" &
           " to list properties, or 'help' / 'h' for help. Ignoring extra.")
      case args[0]
      of "props", "prop", "p":
        output &= "Important Properties: \n"
        output &= ctxChalkConf.spec.get().oneObjTypeToTable(name)
      of "help", "h":
          output = getHelp(helpCorpus, @["help." & name & ".help"])
      else:
        output  = "Invalid argument to 'chalk help " & name
        output &= "'. See 'chalk help " & name & " help' for details\n"

proc filterBySbom(row: seq[string]): bool = return row[1] == "sbom"
proc filterBySast(row: seq[string]): bool = return row[1] == "sast"
proc filterCallbacks(row: seq[string]): bool =
  if row[0] in ["attempt_install", "get_command_args", "get_tool_location",
                "produce_keys", "kind"]: return false
  return true

template handleToolHelp(name: string, toolFilter: untyped) =
  if len(args) == 0:
    let
      sec  = ctxChalkConf.attrs.contents["tool"].get(AttrScope)
      hdrs = @["Tool", "Kind", "Enabled", "Priority"]
      cols = @["kind", "enabled", "priority"]

    output  = sec.objectsToTable(cols, hdrs, filter = toolFilter)
    output &= "See 'chalk help " & name &
           " <TOOLNAME>' for specifics on a tool\n"
  else:
    for arg in args:
      if arg notin chalkConfig.tools:
        error(arg & ": tool not found.")
        continue
      let
        tool  = chalkConfig.tools[arg]
        scope = tool.getAttrScope()

      if tool.kind != name:
        error(arg & ": tool is not a " & name & " tool.  Showing you anyway.")

      output &= scope.oneObjToTable(objType = "tool",
                                    filter = filterCallbacks,
                                    cols = @[fcName, fcValue])
      if tool.doc.isSome():
        output &= tool.doc.get()

proc runCmdHelp*(cmdName: string) {.noreturn.} =
  var
    output: string = ""
    filter: Con4mRowFilter = nil
    args = getArgs()

  case cmdName
  of "help.key":
    var
      skip                = false
      search: seq[string] = @[]
      addFooter           = true
    let
      xform  = { "kind" : Con4mDocXForm(transformKind) }.newTable()
      cols   = @["kind", "type", "doc"]
      kcf    = ctxChalkConf.attrs.contents["keyspec"].get(AttrScope)

    if len(args) > 0:
      case args[0].toLowerAscii():
        of "chalk", "c":
          filter = fChalk
          restAreSearch()
        of "host":
          filter = fHost
          restAreSearch()
        of "artifact", "art", "a":
          filter = fArtifact
          restAreSearch()
        of "report", "r":
          filter = fReport
          restAreSearch()
        of "search", "s":
          search = args[1 .. ^1]
        of "help", "h":
          output = getHelp(helpCorpus, @["help.key.help"])
        else:
          let
            cols = @[fcName, fcValue]
            hdrs = @["Property", "Value"]
          for keyname in args:
            let
              formalKey = keyname.toUpperAscii()
              specOpt   = formalKey.getKeySpec()
            if specOpt.isNone():
              error(formalKey & ": unknown key.\n")
            else:
              let
                keyspec = specOpt.get()
                docOpt  = keySpec.getDoc()
                keyObj  = keySpec.getAttrScope()

              output &= formatTitle(formalKey)
              output &= keyObj.oneObjToTable(cols = cols, hdrs = hdrs,
                                   xforms = xform, objType = "keyspec")
          addFooter = false
    if output == "":
      let hdrs = @["Key Name", "Kind of Key", "Data Type", "Overview"]
      output = kcf.objectsToTable(cols, hdrs, xforms = xform,
                                  filter = filter, searchTerms = search)
    if output == "":
      output = (formatTitle("No results returned for command: '")[0 ..< ^1] &
                "help key " & args.join(" ") & "'\nSee 'help key help'\n")
    elif addFooter:
      output &= "\n"
      output &= """
See: 'chalk help keys <KEYNAME>' for details on specific keys.  OR:
'chalk help keys chalk'         -- Will show all keys usable in chalk marks.
'chalk help keys host'          -- Will show all keys usable in host reports.
'chalk help keys art'           -- Will show all keys specific to artifacts.
'chalk help keys report'        -- Will show all keys meant for reporting only.
'chalk help keys search <TERM>' -- Will return keys matching any term you give.

The first letter for each sub-command also works. 'key' and 'keys' both work.
"""
      output &= "\n"
  of "help.keyspec":
    handleObjTypeHelp("keyspec")
  of "help.tool":
    handleObjTypeHelp("tool")
    output &= "See 'chalk help sast' and 'chalk help sbom' for tool info\n"
  of "help.plugin":
    handleObjTypeHelp("plugin")
  of "help.sink":
    handleObjTypeHelp("sink")
  of "help.outconf":
    handleObjTypeHelp("outconf")
  of "help.report":
    handleObjTypeHelp("custom_report")
  of "help.profile":
    handleObjTypeHelp("profile")
  of "help.sbom":
    handleToolHelp("sbom", filterBySbom)
  of "help.sast":
    handleToolHelp("sast", filterBySast)
  of "help.topics":
    output = getHelp(helpCorpus, @["topics"])
    var otherTopics: seq[string] = @[]
    for key, _ in helpCorpus:
       if "." notin key: otherTopics.add(key)
    output &= "\n" & otherTopics.join(", ") & "\n"
  else:
    output = getHelp(helpCorpus, getArgs())

  publish("help", output)
  quit()

proc runCmdHelp*() {.noreturn.} = runCmdHelp("help")

proc runCmdConfLoad*() =
  initCollection()

  var newCon4m: string
  let filename = getArgs()[0]

  setArtifactSearchPath(@[resolvePath(getAppFileName())])

  let selfChalk = getSelfExtraction().getOrElse(nil)
  allChalks     = @[selfChalk]

  if selfChalk == nil or not canSelfInject:
    error("Platform does not support self-injection.")
    unmarked = @[selfChalk.fullPath]
    return

  if filename == "default":
    newCon4m = defaultConfig
    info("Installing the default confiuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      error(filename & ": could not open configuration file")
      return
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      error(filename & ": could not read configuration file")
      return

    info(filename & ": Validating configuration.")

    # Now we need to validate the config, without stacking it over our
    # existing configuration. We really want to know that the file
    # will not only be a valid con4m file, but that it will meet the
    # chalk spec.
    #
    # We go ahead and execute it, so that it can go through full
    # validation, even though it could easily side-effect.
    #
    # To do that, we need to give it a valid base state, clear of any
    # existing configuration.  So we stash the existing config state,
    # reload the base configs, and then validate the existing spec.
    #
    # And then, of course, restore the old spec when done.

    var
      realEvalCtx = ctxChalkConf
      realConfig  = chalkConfig
    try:
      loadBaseConfiguration()
      var
        testConfig = newStringStream(newCon4m)
        tree       = parse(testConfig, filename)

      tree.checkTree(ctxChalkConf)
      ctxChalkConf.preEvalCheck(c42Ctx)
      tree.initRun(ctxChalkConf)
      tree.evalNode(ctxChalkConf)
      ctxChalkConf.validateState(c42Ctx)
      # Replace the real state.
      ctxChalkConf = realEvalCtx
      chalkConfig  = realConfig
    except:
      ctxChalkConf = realEvalCtx
      chalkConfig  = realConfig
      publish("debug", getCurrentException().getStackTrace())
      error("Could not load config file: " & getCurrentExceptionMsg())
      return

    trace(filename & ": Configuration successfully validated.")

    selfChalk.collectChalkInfo()
    selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)

  trace(filename & ": installing configuration.")
  let oldLocation = selfChalk.fullPath
  selfChalk.fullPath = oldLocation & ".new"
  try:
    copyFile(oldLocation, selfChalk.fullPath)
    let
      toWrite = selfChalk.getChalkMark().toJson()
      rawHash = selfChalk.myCodec.handleWrite(selfChalk, some(toWrite), false)

    info("Configuration written to new binary: " & selfChalk.fullPath)
    selfChalk.postHash = rawHash
  except:
    error("Configuration loading failed: " & getCurrentExceptionMsg())
    selfChalk.opFailed = true

  doReporting()

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
    if len(obj.subscribers) == 0: unusedTopics.add(topic)
    for config in obj.subscribers:
      if config notin subLists: subLists[config] = @[topic]
      else:                     subLists[config].add(topic)

  ot.addRow(@["Config name", "Sink", "Parameters", "Filters", "Topics"])
  for key, config in sinkConfigs:
    if config notin sublists: sublists[config] = @[]
    ot.addRow(@[key,
                config.mySink.getSinkName(),
                paramFmt(config.config),
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
      toPublish &= keyArr.arrayToTable(@["report"], @["Key", "Use?"])

proc showConfig*(force: bool = false) =
  once:
    const nope = "none\n\n"
    if not (chalkConfig.getPublishDefaults() or force): return
    var toPublish = ""
    let
      genCols  = @[fcShort, fcValue, fcName]
      genHdrs  = @["Option", "Value", "Config Key"]
      outCols  = @[fcName, fcValue]
      outHdrs  = @["Report Type", "Profile"]
      ocCol    = @["chalk", "artifact_report", "host_report",
                   "invalid_chalk_report"]
      outconfs = if "outconf" in ctxChalkConf.attrs.contents:
                   ctxChalkConf.attrs.contents["outconf"].get(AttrScope)
                 else: nil
      crCol    = @["enabled", "artifact_profile", "host_profile",
                   "invalid_chalk_profile", "use_when"]
      reports  = if "custom_report" in ctxChalkConf.attrs.contents:
                   ctxChalkConf.attrs.contents["custom_report"].get(AttrScope)
                 else: nil
      tCol     = @["kind", "enabled", "priority", "stop_on_success"]
      tools    = if "tool" in ctxChalkConf.attrs.contents:
                   ctxChalkConf.attrs.contents["tool"].get(AttrScope)
                 else: nil
      piCol    = @["codec", "enabled", "priority", "ignore", "overrides"]
      plugs    = if "plugin" in ctxChalkConf.attrs.contents:
                   ctxChalkConf.attrs.contents["plugin"].get(AttrScope)
                 else: nil
      profs    = if "profile" in ctxChalkConf.attrs.contents:
                   ctxChalkConf.attrs.contents["profile"].get(AttrScope)
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
      toPublish &= formatTitle("Available Profiles")
      toPublish &= profs.listSections("Profile Name")

    toPublish &= formatTitle("General configuration")
    toPublish &= ctxChalkConf.attrs.oneObjToTable(genCols, genHdrs)

    publish("defaults", toPublish)
    if force: showDisclaimer(80)
