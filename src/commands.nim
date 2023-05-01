## This module implements both individual commands, and includes
## --publish-defaults functionality for other commands.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, unicode, os, streams, posix
import config, builtins, collect, chalkjson, plugins, plugins/codecDocker
import macros except error

let emptyReport = toJson(ChalkDict())
var liftableKeys: seq[string] = @[]

proc setPerChalkReports(successProfileName: string,
                        invalidProfileName: string,
                        hostProfileName:    string) =
  var
    reports     = seq[string](@[])
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
    let
      profile   = if not chalk.opFailed: goodProfile else: badProfile
      oneReport = hostInfo.prepareContents(chalk.collectedData, profile)

    if oneReport != emptyReport: reports.add(oneReport)

  # Now, reset any profiles where we performed lifting.
  for key, conf in goodStash: goodProfile.keys[key] = conf
  for key, conf in badStash:  badProfile.keys[key] = conf

  let reportJson = "[ " & reports.join(", ") & "]"
  if len(reports) != 0:       hostInfo["_CHALKS"] = pack(reportJson)
  elif "_CHALKS" in hostInfo: hostInfo.del("_CHALKS")

# Next, our reporting.
template doCommandReport() =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]
    unmarked    = getUnmarked()

  if not hostProfile.enabled: return

  setPerChalkReports(conf.artifactReport, conf.invalidChalkReport,
                     conf.hostReport)
  if len(unmarked) != 0: hostInfo["_UNMARKED"] = pack(unmarked)
  publish("report", hostInfo.prepareContents(hostProfile))

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

    setPerChalkReports(spec.artifactProfile, spec.invalidChalkProfile,
                       spec.hostProfile)
    let profile = chalkConfig.profiles[spec.hostProfile]
    if profile.enabled:
      try:
        publish(topic, hostInfo.prepareContents(profile))
      except:
        error("Publishing to topic '" & topic & "' failed; an exception was " &
          "raised when trying to write to a sink. Please check your sink " &
          "configuration and outbound connectivity.  " &
          getCurrentExceptionMsg() & "\n")

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

proc doReporting() =
  collectPostRunInfo()
  liftUniformKeys()
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
        toWrite = some(item.getChalkMarkAsStr())
        rawHash = item.myCodec.handleWrite(item, toWrite, virtual)

      if virtual: info(item.fullPath & ": virtual chalk created")
      else:       info(item.fullPath & ": chalk mark successfully added")

      item.postHash = rawHash
    except:
      error(item.fullPath & ": insertion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
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
      dumpExOnDebug()
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
    titleCode = toAnsiCode(@[acFont4, acBRed])
    endCode   = toAnsiCode(@[acReset])

  return titleCode & text & endCode & "\n"

template row(x, y, z: string) = ot.addRow(@[x, y, z])

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

proc filterBySbom(row: seq[string]): bool = return row[1] == "sbom"
proc filterBySast(row: seq[string]): bool = return row[1] == "sast"
proc filterCallbacks(row: seq[string]): bool =
  if row[0] in ["attempt_install", "get_command_args", "get_tool_location",
                "produce_keys", "kind"]: return false
  return true

template removeDots(s: string): string = replace(s, ".", " ")
template noExtraArgs(cmdName: string) =
 if len(args) > 0:
  warn("Additional arguments to " & removeDots(cmdName) & " ignored.")

proc getKeyHelp(filter: Con4mRowFilter, noSearch: bool = false): string =
  let
    args   = getArgs()
    xform  = { "kind" : Con4mDocXForm(transformKind) }.newTable()
    cols   = @["kind", "type", "doc"]
    kcf    = getChalkRuntime().attrs.contents["keyspec"].get(AttrScope)

  if noSearch and len(args) > 0:
      let
        cols = @[fcName, fcValue]
        hdrs = @["Property", "Value"]
      for keyname in args:
        let
          formalKey = keyname.toUpperAscii()
          specOpt   = formalKey.getKeySpec()
        if specOpt.isNone():
          error(formalKey & ": unknown Chalk key.\n")
        else:
          let
            keyspec = specOpt.get()
            docOpt  = keySpec.getDoc()
            keyObj  = keySpec.getAttrScope()

          result &= formatTitle(formalKey)
          result &= keyObj.oneObjToTable(cols = cols, hdrs = hdrs,
                               xforms = xform, objType = "keyspec")
  else:
    let hdrs = @["Key Name", "Kind of Key", "Data Type", "Overview"]
    result   = kcf.objectsToTable(cols, hdrs, xforms = xform,
                                  filter = filter, searchTerms = args)
    if result == "":
      result = (formatTitle("No results returned for key search: '")[0 ..< ^1] &
                args.join(" ") & "'\nSee 'help key'\n")
    if noSearch:
      result &= "\n"
      result &= """
See: 'chalk help keys <KEYNAME>' for details on specific keys.  OR:
'chalk help keys chalk'         -- Will show all keys usable in chalk marks.
'chalk help keys host'          -- Will show all keys usable in host reports.
'chalk help keys art'           -- Will show all keys specific to artifacts.
'chalk help keys report'        -- Will show all keys meant for reporting only.
'chalk help keys search <TERM>' -- Will return keys matching any term you give.

The first letter for each sub-command also works. 'key' and 'keys' both work.
"""

proc runChalkHelp*(cmdName: string) {.noreturn.} =
  var
    output: string = ""
    filter: Con4mRowFilter = nil
    args = getArgs()

  case cmdName
  of "help":
    output = getAutoHelp()
    if output == "":
      output = getCmdHelp(getArgCmdSpec(), args)
  of "help.key":
      output = getKeyHelp(filter = nil, noSearch = true)
  of "help.key.chalk":
      output = getKeyHelp(filter = fChalk)
  of "help.key.host":
      output = getKeyHelp(filter = fHost)
  of "help.key.art":
      output = getKeyHelp(filter = fArtifact)
  of "help.key.report":
      output = getKeyHelp(filter = fReport)
  of "help.key.search":
      output = getKeyHelp(filter = nil)

  of "help.keyspec", "help.tool", "help.plugin", "help.sink", "help.outconf",
     "help.custom_report":
       cmdName.noExtraArgs()
       let name = cmdName.split(".")[^1]

       output = formatTitle("'" & name & "' Objects")
       output &= getChalkRuntime().getSectionDocStr(name).get()
       output &= "\n"
       output &= "See 'chalk help " & name
       output &= " props' for info on the key properties for " & name
       output &= " objects\n"

  of "help.keyspec.props", "help.tool.props", "help.plugin.props",
     "help.sink.props", "help.outconf.props", "help.report.props",
     "help.key.props":
       cmdName.noExtraArgs()
       let name = cmdName.split(".")[^2]
       output &= "Important Properties: \n"
       output &= getChalkRuntime().spec.get().oneObjTypeToTable(name)

  of "help.sbom", "help.sast":
    let name       = cmdName.split(".")[^1]
    let toolFilter = if name == "sbom": filterBySbom else: filterBySast

    if len(args) == 0:
      let
        sec  = getChalkRuntime().attrs.contents["tool"].get(AttrScope)
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
  else:
    output = "Unknown command: " & cmdName

  publish("help", output)
  quit()

proc runChalkHelp*() {.noreturn.} = runChalkHelp("help")

template cantLoad(s: string) =
  error(s)
  addUnmarked(selfChalk.fullPath)
  selfChalk.opFailed = true
  doReporting()
  return

proc cmdlineError(err, tb: string): bool =
  error(err)
  return false

proc newConfFileError(err, tb: string): bool =
  error(err & "\n" & tb)
  return false

proc runCmdConfLoad*() =
  initCollection()

  var newCon4m: string

  let filename = getArgs()[0]

  if filename == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCstringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  if filename == "default":
    newCon4m = defaultConfig
    info("Installing the default configuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      cantLoad(filename & ": could not open configuration file")
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      cantLoad(filename & ": could not read configuration file")
      dumpExOnDebug()

    info(filename & ": Validating configuration.")

    let
      toStream = newStringStream
      stack    = newConfigStack().addSystemBuiltins().

                 addCustomBuiltins(chalkCon4mBuiltins).
                 addSpecLoad(chalkSpecName, toStream(chalkC42Spec)).
                 addConfLoad(baseConfName, toStream(baseConfig)).
                 setErrorHandler(newConfFileError).
                 addConfLoad(ioConfName,   toStream(ioConfig)).
                 addConfLoad(signConfName, toStream(signConfig)).
                 addConfLoad(sbomConfName, toStream(sbomConfig)).
                 addConfLoad(sastConfName, toStream(sastConfig))
    stack.run()
    stack.addConfLoad(filename, toStream(newCon4m)).run()

    if not stack.errored:
      trace(filename & ": Configuration successfully validated.")
    else:
      addUnmarked(selfChalk.fullPath)
      selfChalk.opFailed = true
      doReporting()
      return

  selfChalk.collectChalkInfo()
  selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)

  trace(filename & ": installing configuration.")
  let oldLocation = selfChalk.fullPath
  selfChalk.fullPath = oldLocation & ".new"
  try:
    copyFile(oldLocation, selfChalk.fullPath)
    let
      toWrite = some(selfChalk.getChalkMarkAsStr())
      rawHash = selfChalk.myCodec.handleWrite(selfChalk, toWrite, false)

    info("Configuration written to new binary: " & selfChalk.fullPath)
    selfChalk.postHash = rawHash
  except:
    cantLoad("Configuration loading failed: " & getCurrentExceptionMsg())
    dumpExOnDebug()
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

{.warning[CStringConv]: off.}
proc runCmdDocker*() {.noreturn.} =
  var opFailed = false
  
  let
    (cmd, args, flags) = parseDockerCmdline() # in config.nim
    cmdline            = getArgs().join(" ")
    codec              = Codec(getPluginByName("docker"))

  initCollection()

  try:
    case cmd
    of "build":
      if len(args) == 0:
        error("No arguments to docker")
        opFailed = true
      else:
        let chalk = newChalk(FileStream(nil), "<none>:<none>")
        chalk.myCodec = codec
        addToAllChalks(chalk)
        # Let the docker codec deal w/ env vars, flags and docker files.
        if extractDockerInfo(chalk, flags, args[^1]):
          # Then, let any plugins run to collect data.
          chalk.collectChalkInfo()
          # Now, have the codec write out the chalk mark.
          let toWrite    = chalk.getChalkMarkAsStr()
          try:
            chalk.writeChalkMark(toWrite)            
            var wrap = chalkConfig.dockerConfig.getWrapEntryPoint()
            if wrap:
              let selfChalk = getSelfExtraction().getOrElse(nil)
              if selfChalk == nil or not canSelfInject:
                error("Platform does not support entry point rewriting")
              else:
                chalk.writeChalkMark(toWrite)
                selfChalk.collectChalkInfo()
                chalk.prepEntryPointBinary(selfChalk)
                setCommandName("confload")
                let binaryChalkMark = selfChalk.getChalkMarkAsStr()
                setCommandName("docker")
                chalk.writeEntryPointBinary(selfChalk, binaryChalkMark)
                
            if chalk.buildContainer(wrap, flags, getArgs()):
              info(chalk.fullPath & ": container successfully chalked")
              chalk.collectPostChalkInfo()
            else:
              error(chalk.fullPath & ": container NOT built.")
              opFailed = true
          except:
            opFailed = true
            error(getCurrentExceptionMsg())
            error("Above occurred when runnning docker command: " & cmdline)
            dumpExOnDebug()
        else:
          opFailed = true
      doReporting()
    else:
      opFailed = true            
      trace("Unhandled docker command: " & cmdline)
      discard
  except:
    error(getCurrentExceptionMsg())
    error("Above occurred when runnning docker command: " & cmdline)
    dumpExOnDebug()
    opFailed = true
    doReporting()

  if not opFailed: quit(0)

  # This is the fall-back exec for docker when there's any kind of failure.
  let exeOpt = findDockerPath()
  if exeOpt.isSome():
    let exe    = exeOpt.get()
    var toExec = getArgs()

    trace("Execing docker: " & exe & " " & cmdline)
    toExec = @[exe] & toExec
    discard execvp(exe, allocCStringArray(toExec))
    error("Exec of '" & exe & "' failed.")
  else:
    error("Could not find 'docker'.")
  quit(1)

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
    let chalkRuntime = getChalkRuntime()
    var toPublish = ""
    let
      genCols  = @[fcShort, fcValue, fcName]
      genHdrs  = @["Option", "Value", "Config Key"]
      outCols  = @[fcName, fcValue]
      outHdrs  = @["Report Type", "Profile"]
      ocCol    = @["chalk", "artifact_report", "host_report",
                   "invalid_chalk_report"]
      outconfs = if "outconf" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["outconf"].get(AttrScope)
                 else: nil
      crCol    = @["enabled", "artifact_profile", "host_profile",
                   "invalid_chalk_profile", "use_when"]
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
      toPublish &= formatTitle("Available Profiles")
      toPublish &= profs.listSections("Profile Name")

    toPublish &= formatTitle("General configuration")
    toPublish &= chalkRuntime.attrs.oneObjToTable(genCols, genHdrs)

    publish("defaults", toPublish)
    if force: showDisclaimer(80)
