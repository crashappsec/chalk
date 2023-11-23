##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk help` command.

import ../config, ../sinks

const helpFiles = newFileTable("../docs/")

# This one should be gotten via API call, not hardcoded.
const allConfigVarSections = ["", "docker", "exec", "extract", "env_config",
                              "source_marks"]

# Same here, should generate via API.
const allCommandSections = ["", "insert", "docker", "extract", "extract.images",
                            "extract.containers", "extract.all", "exec",
                            "setup", "setup.gen", "setup.load", "env",
                            "config", "dump", "load", "delete", "version"]

proc kindEnumToString(s, v: string): string =
  case v
  of "0":
    "Chalk-Time, Host"
  of "1":
    "Chalk-Time, Artifact"
  of "2":
    "Run-Time, Artifact"
  of "3":
    "Run-Time, Host"
  else:
    "Unknown"

var transformers  = TransformTableRef()

proc getKeyspecTable(state:          ConfigState, 
                     filterValueStr: string,
                     fieldsToUse:    openarray[string]): Rope =

  const headingsToUse = ["Key", "Collection Type", "Value Type", "Description"]



  let caption = atom("See ") + em("help key <term>") + 
                atom(" to search the table only")

  result = state.getInstanceDocs("keyspec",
                                 fieldsToUse    = fieldsToUse,
                                 searchFields   = ["kind"],
                                 searchTerms    = [filterValueStr],
                                 headings       = headingsToUse,
                                 transformers   = transformers,
                                 caption        = caption)

  result.colPcts([25, 15, 25, 35])
  

proc keyHelp(state: ConfigState, args: seq[string] = @[], summary = false):
            Rope =
  var 
    filter: bool  = false
    fieldsToUse   = @["kind", "type"]

  if summary:
    fieldsToUse.add("shortdoc")
  else:
    fieldsToUse.add("doc")

  transformers["kind"] = FieldTransformer(kindEnumToString)

  case len(args)
  of 0, 1:
    result = state.getKeyspecTable("", fieldsToUse)
  of 2:
    case args[1].toLowerAscii()
    of "help", "--help":
      result = markdown("""
`chalk help keys` gives a table with all metadata keys.

`chalk help keys <<filter>>` will filter the list by category.  Valid
values for the filter are:

- chalk (or chalk-time); Shows all keys that can be added into chalk marks
- runtime (or run-time); Shows all keys that can be reported for non-chalk ops
- artifact; Shows all keys that collect metadata on a per-artifact basis
- host; Shows all keys that collect metadata on a host basis only.

Additionally, you can search for any text within metadata help via
`chalk help keys <<search terms>>`. When multiple words are provided,
any word that matches is returned.
""")
    of "chalk", "chalk-time", "chalktime":
      result = h1("Chalk-Time Host Metadata Keys")
      result += state.getKeyspecTable("0", fieldsToUse)
      result += h1("Chalk-Time Artifact Metadata Keys")
      result += state.getKeyspecTable("1", fieldsToUse)
    of "runtime", "run-time":
      result = h1("Run-Time Artifact Metadata Keys")
      result += state.getKeyspecTable("2", fieldsToUse)
      result += h1("Run-Time Host Metadata Keys")
      result += state.getKeyspecTable("3", fieldsToUse)
    of "host":
      result += h1("Chalk-Time Host Metadata Keys")
      result += state.getKeyspecTable("0", fieldsToUse)
      result += h1("Run-Time Host Metadata Keys")
      result += state.getKeyspecTable("3", fieldsToUse)
    of "artifact":
      result = h1("Chalk-Time Artifact Metadata Keys")
      result += state.getKeyspecTable("1", fieldsToUse)
      result += h1("Run-Time Artifact Metadata Keys")
      result += state.getKeyspecTable("2", fieldsToUse)
    else:
      filter = true
  else:
    filter = true

  if filter:
    result = state.getInstanceDocs("keyspec",
                                  ["kind", "type", "doc"],
                                  searchFields = ["doc", "shortdoc"],
                                  searchTerms = args[1 .. ^1],
                                  headings = ["Key",
                                              "Collection Type",
                                              "Value Type",
                                              "Description"],
                                  transformers = transformers)

proc resolveHelpFileName(docName: string): string =
  if docName.startsWith("core-"):
    result = docName[5 .. ^1]
  elif docName.startsWith("howto-") or docName.startsWith("guide-"):
    result = docName[6 .. ^1]
  else:
    result = docName

proc searchEmbeddedDocs(terms: seq[string]): Rope =
  # Terminal only.
  for key, doc in helpfiles:
    var matchedTerms: seq[string] = @[]

    for term in terms:
      if term in doc:
        matchedTerms.add(term)

    if len(matchedTerms) != 0:
      let docName = resolveHelpFileName(key)

      result += h4("Match on document: " & docName)
      result += text(doc).highlightMatches(matchedTerms)

  if result == Rope(nil):
    result = h4("No matches in other documents.")

proc searchMetadataKeys(state: ConfigState, terms: seq[string]): Rope =
  var transformers     = TransformTableRef()
  transformers["kind"] = FieldTransformer(kindEnumToString)

  var
    matches: seq[seq[string]] 
    baseDocs = state.getAllInstanceDocsAsArray("keyspec",
                                               ["kind", "type", "doc"],
                                                transformers)
  for doc in baseDocs:
    var addIt = false
    for term in terms:
      for cell in doc:
        if term in cell:
          addIt = true
          break

    if addIt:
      matches.add(doc)

  if len(matches) == 0:
    result = h4("No matches in found metadata key docs")
  else:
    matches = @[@["Key", "Collection Type", "Value Type", "Description"]] & 
      matches
    result = quickTable(matches, title = "Metadata documentation matches",
                        class = "help")
    result = result.highlightMatches(terms)

proc searchConfigVars(state: ConfigState, args: seq[string]): Rope =
  for sec in allConfigVarSections:
    let matches = state.getMatchingConfigOptions(sec, filterTerms = args)
    if matches == Rope(nil):
      continue
    for match in matches.searchOne(@["table"]).get().tbody.cells:
      var 
        caption: string
        tdCells = match.search(@["td"])
      if len(tdCells) == 0:
        continue
      if sec == "":
        caption = "Match in global configuration variable"
      else:
        caption = "Match in configuration section " & sec &
                  " for variable: " &  tdCells[0].asUtf8()
      result += quickTable(@[
          @[atom("Description"), tdCells[3].contained],
          @[atom("Config value type"), tdCells[1].contained],
          @[atom("Default value"), tdCells[2].contained]],
              class = "help", title = caption, verticalHeaders = true)

  if result == Rope(nil):
    result = h4("No matches in configuration variables")

proc formatCommandName(dotted: string): string =
  let parts = dotted.split(".")

  if len(parts) == 1:
    return "Command " & parts[0]
  else:
    return "Command " & parts[0] & "'s sub-command " & parts[1]

proc searchFlags(state: ConfigState, args: seq[string]): Rope =
  for command in allCommandSections:
    let objs = state.getCommandFlagInfo(command, args)

    if len(objs) == 0:
      continue

    for match in objs:
      var 
        cells:    seq[seq[string]]
        heading = "Match for "
        ftStr: string

      if command == "":
        heading &= "global flag " & match.flagName
      else:
        heading &= "flag " & match.flagName & " from " & 
                    command.formatCommandName()
      result += h4(heading)
      
      case match.kind
      of "boolean":      ftStr = "Yes / No (boolean)"
      of "arg":          ftStr = "Required Argument"
      of "multi-arg":    ftStr = "Multiple Arguments"
      of "choice":       ftStr = "Choice"
      of "multi-choice": ftStr = "Multiple Choice"
      else:              ftStr = "Unknown"

      cells = @[@["Flag", match.flagName],
                @["Flag Type", ftStr]]
                 
      if match.sets != "":
        cells.add(@["Config variable set", match.sets])

      if match.choices.len() != 0:
        cells.add(@["Valid choices", match.choices.join(", ")])
        if match.autoFlags:
          cells.add(@["Choices are also valid flags", "(Yup!)"])

      result += quickTable(cells, verticalHeaders = true, class = "help")

  if result == Rope(nil):
    result = h4("No matches found in command-line flag documentation")

proc searchCommandDescriptions(state: ConfigState, args: seq[string]): Rope =
  let matches = state.getCommandNonFlagData(allCommandSections, args)

  if matches == nil:
    result = h4("No matches in command descriptions")

  result = matches.highlightMatches(args)


proc getHelpTopics(state: ConfigState): Rope =
  result  = h1("Additional help topics")
  result += h2(atom("Use ") + em("chalk help <topicname>") + atom(" to read"))
  
  var items: seq[string]
  for k, _ in helpFiles:
    items.add(resolveHelpFileName(k))

  result += ul(items)

proc getSinkHelp(state: ConfigState): Rope =
  result = h2("Available output sinks")
  result += text("""
As mentioned above, if you wish to control where to send reporting
data, you can create a `sink_config` object that configures one of the
below sink types. The descriptions for each sink type describe what
fields are required or allowed for each kind of sink.""

Remember that to use a sink, you need to either assign it to a custom
report, or """, pre = false)
  result += em("subscribe()") + text("it to a topic.")

  result += state.getInstanceDocs("sink", ["shortdoc", "doc"],
                               ["Overview", "Detail"])

proc getPluginHelp(state: ConfigState): Rope =
  let 
    keyFields = ["pre_run_keys", "artifact_keys", "post_chalk_keys",
                 "post_run_keys"]
    kfNames   = ["Chalk-time host metadata",
                 "Chalk-time artifact metadata",
                 "Post-chalk host metadata",
                 "Post-chalk artifact metadata"]

    allDocs = state.getAllInstanceRawDocs("plugin")

  for plugin, docs in allDocs:
    result += h2(text("Plugin: ") + em(plugin))
    result += h3("Overview")
    if "doc" in docs:
      result += markdown(docs["doc"]["value"])
    else:
      result += text("No documentation.")

    for i, item in keyFields:
      if item in docs:
        let 
          asJson = docs[item]["value"].parseJson()
          asArr  = asJson.to(seq[string])

        if len(asArr) != 0:
          result += asArr.instantTable(kfNames[i])


proc getMarkTemplateDocs(state: ConfigState): Rope =
  result = state.getInstanceDocs("mark_template", ["shortdoc"],
                                 headings = ["Template Name", "Description"],
                                 title = atom("Chalk Mark Templates"))

proc getReportTemplateDocs(state: ConfigState): Rope =
  result = state.getInstanceDocs("report_template", ["shortdoc"],
                                 headings = ["Template Name", "Description"],
                                 title = atom("Report Templates"))

proc formatOneTemplate(state: ConfigState,
                     tmpl: MarkTemplate | ReportTemplate): Rope =
  var
    keysToReport: seq[string]

  result = markdown(tmpl.doc.getOrElse("No description available."))

  for k, v in tmpl.keys:
    if v.use == true:
      keysToReport.add(k)

  if len(keysToReport) == 0:
    result += h3("This template is empty, and will only produce default values")
  else:
    result += instantTable(keysToReport,
              "Keys this template produces (beyond any required defaults)")

proc getTemplateHelp(state: ConfigState, args: seq[string]): Rope =
    result  = state.getReportTemplateDocs()
    result += state.getMarkTemplateDocs()

    if len(args) == 0:
      result += callout("""To see details on a template's contents,
do `chalk help template [name]`
or `chalk help template all` to see all templates.

See `chalk help reporting` for more information on templates.
""")
      return

    var
      markTemplates:   seq[string]
      reportTemplates: seq[string]

    if "all" in args:
      for k, v in chalkConfig.markTemplates:
        markTemplates.add(k)
      for k, v in chalkConfig.reportTemplates:
        reportTemplates.add(k)
    else:
      for item in args:
        if item notin chalkConfig.markTemplates and
           item notin chalkConfig.reportTemplates:
          result += h3("No template found named: " & item )
        else:
          if item in chalkConfig.markTemplates:
            markTemplates.add(item)
          if item in chalkConfig.reportTemplates:
            reportTemplates.add(item)

    if len(markTemplates) + len(reportTemplates) == 0:
      result += h1("No matching templates found.")
      return

    for markTmplName in markTemplates:
      let theTemplate = chalkConfig.markTemplates[markTmplName]

      result += h2("Mark Template: " & markTmplName)
      result += state.formatOneTemplate(theTemplate)

    for repTmplName in reportTemplates:
      let theTemplate = chalkConfig.reportTemplates[repTmplName]

      result += h2("Report Template: " & repTmplName)
      result += state.formatOneTemplate(theTemplate)

proc fullTextSearch(state: ConfigState, args: seq[string]): Rope =
  var txt = "Searching documentation for term"

  if len(args) == 1:
    txt &= ": " & args[0]
  else:
    txt &= "s: " & args.join(", ") 

  result = h4(txt)

  result += state.searchCommandDescriptions(args)
  result += state.searchFlags(args)
  result += state.searchConfigVars(args)
  result += state.searchMetadataKeys(args)
  result += searchEmbeddedDocs(args)

  # TODO:
  # - Search sinks.
  # - Search sink configs.
  # - Search templates.
  # - Search developer docs.

proc getOutputHelp(state: ConfigState): Rope =
  let
    (_, mtlong)     = state.getSectionDocs("mark_template")
    (_, rtlong)     = state.getSectionDocs("report_template")
    (_, oclong)     = state.getSectionDocs("outconf")
    (_, sconflong)  = state.getSectionDocs("sink_config")
    (_, custlong)   = state.getSectionDocs("custom_report")

  result  = mtlong
  result += rtlong
  result += oclong
  result += sconflong
  result += custlong

  result += state.getSinkHelp()

proc hasHelpFlag(args: seq[string]): bool =
  for item in args:
    if not item.startswith("-"):
      continue
    var s = item[1 .. ^1]
    while s.startswith("-"):
      s = s[1 .. ^1]

    if s in ["help", "h"]:
      return true

proc makeColorTable(): Rope =
  perClassStyles["light"] = newStyle(fgColor = "white")
  perClassStyles["dark"]  = newStyle(fgColor = "black" )
  styleMap.del("tr.even")
  styleMap.del("tr.odd")
  styleMap["tr"] = newStyle(bgColor = "default")
  var cells: seq[seq[Rope]]

  for color, v in colorTable:
    let cell = center(td(atom(color)).bgColor(color).tpad(1).bpad(1))
    if v < 0x400000:
      cell.setClass("light")
    else:
      cell.setClass("dark")
    cells.add(@[cell])

  return quickTable(cells, "Named colors", noHeaders = true, borders = HorizontalInterior)

proc runChalkHelp*(cmdName = "help") {.noreturn.} =
  var
    args         = getArgs()
    con4mRuntime = getChalkRuntime()
    toOut: Rope

  if cmdName != "help":
    # In this branch, the --help flag got passed, and we will check to
    # see if the command was explicitly passed, or if it was implicit.
    # If it was implicit, give the help overview instead of the command
    # overview.
    let defaultCmd = chalkConfig.getDefaultCommand().getOrElse("")
    if defaultCmd != "" and defaultCmd notin commandLineParams():
      toOut = con4mRuntime.getHelpOverview()
    else:
      toOut = con4mRuntime.getCommandDocs(cmdName)
  elif len(args) == 0 or args.hasHelpFlag():
    toOut = con4mRuntime.getHelpOverview()
  elif args[0] in ["metadata", "keys", "key"]:
      toOut = con4mRuntime.keyHelp(args)
  elif args[0] == "search":
    toOut = con4mRuntime.fullTextSearch(args[1 .. ^1])
  elif args[0] in ["template", "templates"]:
    toOut += con4mRuntime.getTemplateHelp(args[1 .. ^1])
  else:
    for arg in args:
      case arg
      of "nikon":
        toOut += makeColorTable()
      of "output", "reports", "reporting":
        toOut += con4mRuntime.getOutputHelp()
      of "plugins":
        toOut += con4mRuntime.getPluginHelp()
      of "insert", "delete", "env", "dump", "load", "config",
         "version", "docker", "exec":
        toOut += con4mRuntime.getCommandDocs(arg)
      of "extract":
        toOut += con4mRuntime.getCommandDocs("extract")
        toOut += con4mRuntime.getCommandDocs("extract.containers")
        toOut += con4mRuntime.getCommandDocs("extract.images")
        toOut += con4mRuntime.getCommandDocs("extract.all")
      of "setup":
        toOut += con4mRuntime.getCommandDocs("setup")
        toOut += con4mRuntime.getCommandDocs("setup.gen")
        toOut += con4mRuntime.getCommandDocs("setup.load")
      of "commands":
        toOut += con4mRuntime.getCommandDocs("")
      of "configuration", "configurations", "conffile", "configs", "conf":
        for section in allConfigVarSections:
          toOut += con4mRuntime.getConfigOptionDocs(section)
      of "topics":
        toOut += con4mRuntime.getHelpTopics()
      of "builtins":
        toOut = con4mRuntime.getBuiltinsTableDoc()
      else:
        let toCheck = [arg, "core-" & arg, "howto-" & arg, "guide" & arg]
        var gotIt = false

        for item in toCheck:
          if item in helpFiles:
            toOut += text(helpFiles[item])
            gotit = true
            break

        if gotIt == false:
          # If we see an unknown argument at any position, stop what
          # we were doing and run a full-text search on all passed
          # arguments.
          toOut = con4mRuntime.fullTextSearch(args)
          break

  if chalkConfig.getUsePager():
    runPager($(toOut))
  else:
    print(toOut)
  quit(0)

const
  docDir   = "chalk-docs"
  cmdline  = docDir.joinPath("command-line.md")
  conffile = docDir.joinPath("config-file.md")
  outconf  = docDir.joinPath("output-config.md")
  keyinfo  = docDir.joinPath("metadata.md")
  builtins = docDir.joinPath("builtins.md")

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

proc buildSinkConfigData(): seq[seq[Rope]] =
  var
    sinkConfigs = getSinkConfigs()
    subLists:     Table[SinkConfig, seq[string]]

  for topic, obj in allTopics:
    let subscribers = obj.getSubscribers()

    for config in subscribers:
      if config notin subLists: subLists[config] = @[topic]
      else:                     subLists[config].add(topic)

  for key, config in sinkConfigs:
    if config notin sublists:
      sublists[config] = @[]
    result.add(@[text(key), text(config.mySink.getName()), 
                 text(paramFmt(config.params)),
                text(filterFmt(config.filters)), 
                text(sublists[config].join(", "))])

proc getConfigValues(): Rope =

  var
    state          = getChalkRuntime()
    cols           = [CcVarName, CcShort, CcCurValue]
    outConfFields  = ["report_template", "mark_template"]
    cReportFields  = ["enabled", "report_template", "use_when"]
    sinkCfgFields  = ["sink", "filters"]
    plugFields     = ["enabled", "priority", "ignore", "overrides"]
    confHdrs       = ["Config Variable", "Description", "Current Value"]
    outConfData    = @[@[atom("Operation"), atom("Reporting Template"),
                         atom("Chalk Mark Template")]]
    custRepData    = @[@[atom("Name"), atom("Enabled"), atom("Template"),
                        atom("Operations where applied")]]
    codecData      = @[@[atom("Name"), atom("Enabled"), atom("Priority"), 
                         atom("Ignore"), atom("Overrides")]]
    pluginData     = @[@[atom("Name"), atom("Enabled"), atom("Priority"), 
                         atom("Ignore"), atom("Overrides")]]
    sinkCfgData    = @[@[atom("Config Name"), atom("Sink"), atom("Parameters"),
                         atom("Filters"), atom("Topics")]]
    fn             = getValuesForAllObjects

  outConfData    &= fn(state, "outconf",       outConfFields)
  custRepData    &= fn(state, "custom_report", cReportFields)
  sinkCfgData    &= buildSinkConfigData()
  codecData      &= fn(state, "plugin", plugFields, false, ["true"],
                       ["codec"])
  pluginData     &= fn(state, "plugin", plugFields, false, ["false"],
                         ["codec"])

  for item in allConfigVarSections:
    let hdr = if item == "": 
                "Global configuration variables"
              else:
                "Configuration variables in the '" & item & "' section"
    result += state.getMatchingConfigOptions(item, cols = cols, title = hdr,
                            headings = confHdrs, sectionPath = item)


  result += outconfData.quickTable("Metadata template configuration", 
                                   class = "help")
  result += custRepData.quickTable("Additional reports configured",
                                   class = "help")
  result += sinkCfgData.quickTable("I/O configuration", class = "help")
  result += codecData.quickTable("Codecs", class = "help")
  result += pluginData.quickTable("Additional Data Collectors",
                                   class = "help")

proc showConfigValues*(force = false) =
  once:
    if not (chalkConfig.getShowConfig() or force): return

    let toOut = getConfigValues()

    if chalkConfig.getUsePager():
      runPager($(toOut))
    else:
      print(toOut)

proc runChalkDocGen*() =
  var
    f: FileStream
    con4mRuntime = getChalkRuntime()

  createDir(docDir)
  # 1. Write out command docs.
  f = newFileStream(cmdline, fmWrite)
  for item in allCommandSections:
    f.write(con4mRuntime.getCommandDocs(item).toHtml())
  f.close()

  # 2. Write out the configuration file docs.
  f = newFileStream(conffile, fmWrite)
  for section in allConfigVarSections:
    f.write(con4mRuntime.getConfigOptionDocs(expandDocField = false).
                                                       toHtml())
  f.close()

  # 3. Write out the output config doc.
  f = newFileStream(outconf, fmWrite)
  f.write(con4mRuntime.getOutputHelp().toHtml())
  f.close()

  # 4. The metadata reference
  f = newFileStream(keyinfo, fmWrite)
  f.write(con4mRuntime.keyHelp().toHtml())
  f.close()

  # 5. Output the reference on config builtins.
  f = newFileStream(builtins, fmWrite)
  f.write(con4mRuntime.getBuiltinsTableDoc().toHtml())
  f.close()
