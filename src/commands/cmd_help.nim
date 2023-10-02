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

# template dbug(a, b) = print("<jazzberry>" & a & ": </jazzberry>" & b)

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

proc displayPluginKeys(s, v: string): string =
  let
    asJson = parseJson(v)
    asArr  = to(asJson, seq[string])

  if asArr.len() == 0:
    return "<i>None</i>"
  elif asArr.len() == 1 and asArr[0] == "*":
    return "Any"
  return asArr.join(", ")

template getKeyspecTable(state: ConfigState, filterValueStr: string): string =
  state.getAllInstanceDocs("keyspec",
                           fieldsToUse = fieldsToUse,
                           filterField = "kind",
                           filterValue = filterValueStr,
                           headings = headingsToUse,
                           transformers = transformers,
                           docKind      = docKind,
                           markdownFields = mdFields)

proc keyHelp(state: ConfigState, args: seq[string] = @[],
             summary = false,
             docKind = CDocConsole) :string =
  var
    transformers = TransformTableRef()
    filter: bool = false
    mdFields     = @["doc"]
    fieldsToUse  = @["kind", "type"]
    headingsToUse = @["Key", "Collection Type", "Value Type", "Description"]

  if summary:
    fieldsToUse.add("shortdoc")
  else:
    fieldsToUse.add("doc")

  transformers["kind"] = FieldTransformer(kindEnumToString)

  case len(args)
  of 0, 1:
    result = state.getKeyspecTable("")
  of 2:
    case args[1].toLowerAscii()
    of "help", "--help":
      result = """
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
"""
    of "chalk", "chalk-time", "chalktime":
      result = "# Chalk-Time Host Metadata Keys"
      result &= state.getKeyspecTable("0")
      result = "# Chalk-Time Artifact Metadata Keys"
      result &= state.getKeyspecTable("1")
    of "runtime", "run-time":
      result = "# Run-Time Artifact Metadata Keys"
      result &= state.getKeyspecTable("2")
      result = "# Run-Time Host Metadata Keys"
      result &= state.getKeyspecTable("3")
    of "host":
      result = "# Chalk-Time Host Metadata Keys"
      result &= state.getKeyspecTable("0")
      result = "# Run-Time Host Metadata Keys"
      result &= state.getKeyspecTable("3")
    of "artifact":
      result = "# Chalk-Time Artifact Metadata Keys"
      result &= state.getKeyspecTable("1")
      result = "# Run-Time Artifact Metadata Keys"
      result &= state.getKeyspecTable("2")
    else:
      filter = true
  else:
    filter = true

  if filter:
    result = state.searchInstanceDocs("keyspec",
                                  ["kind", "type", "doc"],
                                  searchFields = ["doc", "shortdoc"],
                                  searchTerms = args[1 .. ^1],
                                  headings = ["Key",
                                              "Collection Type",
                                              "Value Type",
                                              "Description"],
                                  transformers = transformers,
                                  markdownFields=["shortdoc", "doc"])

proc highlightMatches(s: string, terms: seq[string]): string =
  result = s
  for term in terms:
    result = result.replace(term, "<strong><em>" & term & "</em></strong>")

proc resolveHelpFileName(docName: string): string =
  if docName.startsWith("core-"):
    result = docName[5 .. ^1]
  elif docName.startsWith("howto-") or docName.startsWith("guide-"):
    result = docName[6 .. ^1]
  else:
    result = docName

proc searchEmbeddedDocs(terms: seq[string]): string =
  # Terminal only.
  for key, doc in helpfiles:
    var matchedTerms: seq[string] = @[]

    for term in terms:
      if term in doc:
        matchedTerms.add(term)

    if len(matchedTerms) != 0:
      let docName = resolveHelpFileName(key)

      result &= "<h2>Match on document: " & docName & "</h2>"
      result &= doc.highlightMatches(matchedTerms)

  if result == "":
    result = "<h2>No matches in other documents.</h2>"

proc searchMetadataKeys(state: ConfigState, terms: seq[string]): string =
  var transformers     = TransformTableRef()
  transformers["kind"] = FieldTransformer(kindEnumToString)

  var
    matches: seq[seq[string]]
    baseDocs  = state.getAllInstanceDocsAsArray("keyspec",
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
    result = "<h2>No matches in found metadata key docs</h2>"
  else:
    let
      preHighlight = matches.formatCellsAsHtmlTable(
           ["Key", "Collection Type", "Value Type", "Description"])
      toShow       = preHighlight.highlightMatches(terms)

    result = "<h2>Metadata documentation matches</h2>" & toShow

proc searchConfigVars(state: ConfigState, args: seq[string]): string =
  for sec in allConfigVarSections:
    let matches = state.getMatchingConfigOptions(sec, filterTerms = args)
    if len(matches) == 0:
      continue
    for match in matches:
      if sec == "":
        result &= "<h2>Match in global configuration variable: "
      else:
        result &= "<h2>Match in configuration section " & sec &
          " for variable: "
      result &= match[0] & "</h2>"
      result &= "<table><tbody><tr><th>Description</th><td>" & match[3]
      result &= "</td></tr>"
      result &= "<tr><th>Config value type</th><td>" & match[1]
      result &=  "</td></tr>"
      result &= "<tr><th>Default value</th></td><td>" & match[2]
      result &= "</td></tr></tbody></table>"

  if result == "":
    result = "<h2>No matches in configuration variables</h2>"

proc formatCommandName(dotted: string): string =
  let parts = dotted.split(".")

  if len(parts) == 1:
    return "Command " & parts[0]
  else:
    return "Command " & parts[0] & "'s sub-command " & parts[1]

proc searchFlags(state: ConfigState, args: seq[string]): string =
  for command in allCommandSections:
    let objs = state.getCommandFlagInfo(command, args)

    if len(objs) == 0:
      continue

    for match in objs:
      result &= "<h2>Match for "
      if command == "":
        result &= "global flag " & match.flagName
      else:
        result &= "flag " & match.flagName & " from " & command.formatCommandName()
      result &= "</h2>"

      result &= "<table><tbody>"
      result &= "<tr><th>Flag</th><td>" & match.flagName & "</td></tr>"
      result &= "<tr><th>Flag Type</th><td>"

      case match.kind
      of "boolean":      result &= "Yes / No (boolean)"
      of "arg":          result &= "Required Argument"
      of "multi-arg":    result &= "Multiple Arguments"
      of "choice":       result &= "Choice"
      of "multi-choice": result &= "Multiple Choice"
      else:              result &= "Unknown"

      result &= "</td></tr>"

      if match.sets != "":
        result &= "<tr><th>Config variable set</th><td>" & match.sets & "</td></tr>"

      if match.choices.len() != 0:
        result &= "<tr><th>Valid choices</th></td>" & match.choices.join(", ") & "</td></tr>"
        if match.autoFlags:
          result &= "<tr><th>Choices are also valid flags:</th><td>Yes</td></tr>"

      result &= "</tbody></table>"

      result &= match.doc

  if result == "":
    result = "<h2>No matches found in command-line flag documentation</h2>"

proc searchCommandDescriptions(state: ConfigState, args: seq[string]): string =
  let matches = state.getCommandNonFlagData(allCommandSections, args)

  if len(matches) == 0:
    result &= "<h2>No matches in command descriptions</h2>"

  else:
    for match in matches:
      var aliases = match[3].highlightMatches(args)

      if aliases == "": aliases = "<em>None</em>"

      result &= "<h2>Match for " & formatCommandName(match[0]) & "</h2>"
      result &= "<table><tbody>"
      result &= "<tr><th>Overview</th><td>" & match[1].highlightMatches(args) & "</td></tr>"
      result &= "<tr><th>Aliases</th><td>" & aliases & "</td></tr>"
      result &= "<tr><th>Arguments</th><td>" & match[4].highlightMatches(args) & "</td></tr>"
      result &= "</tbody></table>"
      result &= match[2]

proc getHelpTopics(state: ConfigState): string =
  result &= "<h1>Additional help topics </h1>"
  result &= "<h2>Use `chalk help <topicname>` to read</h2>"
  result &= "<ul>"

  for k, _ in helpFiles:
    result &= "<li>" & resolveHelpFileName(k) & "</li>"

  result &= "</ul>"

  result = result.stylize()

proc getSinkHelp(state: ConfigState, docType = CDocConsole): string =
  result = """

## Available output sinks

As mentioned above, if you wish to control where to send reporting
data, you can create a `sink_config` object that configures one of the
below sink types. The descriptions for each sink type describe what
fields are required or allowed for each kind of sink.

Remember that to use a sink, you need to either assign it to a custom
report, or `subscribe()` it to a topic.
"""
  result &= "\n\n" & state.getAllInstanceDocs("sink",
          ["shortdoc", "doc"], ["Overview", "Detail"],
          docKind = docType, table = false)

proc getPluginHelp(state: ConfigState): string =
  var
    transformers = TransformTableRef()
    arrayXfm     = FieldTransformer(displayPluginKeys)
  transformers["pre_run_keys"]    = arrayXfm
  transformers["artifact_keys"]   = arrayXfm
  transformers["post_chalk_keys"] = arrayXfm
  transformers["post_run_keys"]   = arrayXfm
  result = state.getAllInstanceDocs("plugin",
          ["doc", "pre_run_keys", "artifact_keys", "post_chalk_keys",
           "post_run_keys"],
          ["Overview", "Chalk-time host metadata",
                      "Chalk-time artifact metadata",
                      "Post-chalk host metadata",
                      "Post-chalk artifact metadata"],
          transformers=transformers,
          table=false,
          markdownFields=["doc"])

  result = result.stylize()

proc getMarkTemplateDocs(state: ConfigState): string =
    result = stylize("# Chalk Mark Templates")

    result &= state.getAllInstanceDocs("mark_template",["shortdoc"],
                                       ["Template Name", "Description"])

proc getReportTemplateDocs(state: ConfigState): string =
  result = stylize("# Report Templates")
  result &= state.getAllInstanceDocs("report_template",["shortdoc"],
                                       ["Template Name", "Description"])

proc formatOneTemplate(state: ConfigState,
                     tmpl: MarkTemplate | ReportTemplate): string =
  var
    keysToReport: seq[string]

  result &= tmpl.doc.getOrElse("No description available.").stylize()

  for k, v in tmpl.keys:
    if v.use == true:
      keysToReport.add(k)

  if len(keysToReport) == 0:
    result &= stylize("<h3>This template is empty, and will only " &
                      "produce default values </h3>")
  else:
    result &= stylize("<h3>Keys this template produces (beyond " &
                      "any required defaults): </h3>")

    result &= instantTable(keysToReport)

proc getTemplateHelp(state: ConfigState, args: seq[string]): string =
    result &= state.getReportTemplateDocs()
    result &= state.getMarkTemplateDocs()

    if len(args) == 0:
      result &= instantTable(@["""To see details on a template's contents,
do `chalk help template [name]`
or `chalk help template all` to see all templates.

See `chalk help reporting` for more information on templates.
"""])
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
          result &= stylize("<h3>No template found named: " & item & "<h3>")
        else:
          if item in chalkConfig.markTemplates:
            markTemplates.add(item)
          if item in chalkConfig.reportTemplates:
            reportTemplates.add(item)

    if len(markTemplates) + len(reportTemplates) == 0:
      result &= stylize("<h1>No matching templates found.</h1>")
      return

    for markTmplName in markTemplates:
      let theTemplate = chalkConfig.markTemplates[markTmplName]

      result &= stylize("<h2>Mark Template: " & markTmplName & "</h2>")
      result &= state.formatOneTemplate(theTemplate)

    for repTmplName in reportTemplates:
      let theTemplate = chalkConfig.reportTemplates[repTmplName]

      result &= stylize("<h2>Report Template: " & repTmplName & "</h2>")
      result &= state.formatOneTemplate(theTemplate)

proc fullTextSearch(state: ConfigState, args: seq[string]): string =
  result &= "<h1>Searching documentation for term"

  if len(args) == 1:
    result &= ": " & args[0] & "</h1>"

  else:
    result &= "s: " & args.join(", ") & "</h1>"

  result &= state.searchCommandDescriptions(args)
  result &= state.searchFlags(args)
  result &= state.searchConfigVars(args)
  result &= state.searchMetadataKeys(args)
  result &= searchEmbeddedDocs(args)
  result = result.stylize()

  # TODO:
  # - Search sinks.
  # - Search sink configs.
  # - Search templates.
  # - Search developer docs.

proc getOutputHelp(state: ConfigState, kind = CDocConsole): string =
  let
    (_, mtlong)     = state.getSectionDocs("mark_template", kind)
    (_, rtlong)     = state.getSectionDocs("report_template", kind)
    (_, oclong)     = state.getSectionDocs("outconf", kind)
    (_, sconflong)  = state.getSectionDocs("sink_config", kind)
    (_, custlong) = state.getSectionDocs("custom_report", kind)

  result  = mtlong
  result &= rtlong
  result &= oclong
  result &= sconflong
  result &= custlong

  result &= state.getSinkHelp(kind)

proc hasHelpFlag(args: seq[string]): bool =
  for item in args:
    if not item.startswith("-"):
      continue
    var s = item[1 .. ^1]
    while s.startswith("-"):
      s = s[1 .. ^1]

    if s in ["help", "h"]:
      return true

proc runChalkHelp*(cmdName = "help") {.noreturn.} =
  var
    args         = getArgs()
    toOut        = ""
    con4mRuntime = getChalkRuntime()

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
    toOut &= con4mRuntime.getTemplateHelp(args[1 .. ^1])
  else:
    for arg in args:
      case arg
      of "output", "reports", "reporting":
        toOut &= con4mRuntime.getOutputHelp()
      of "plugins":
        toOut &= con4mRuntime.getPluginHelp()
      of "insert", "delete", "env", "dump", "load", "config",
         "version", "docker", "exec":
        toOut &= con4mRuntime.getCommandDocs(arg)
      of "extract":
        toOut &= con4mRuntime.getCommandDocs("extract")
        toOut &= con4mRuntime.getCommandDocs("extract.containers")
        toOut &= con4mRuntime.getCommandDocs("extract.images")
        toOut &= con4mRuntime.getCommandDocs("extract.all")
      of "setup":
        toOut &= con4mRuntime.getCommandDocs("setup")
        toOut &= con4mRuntime.getCommandDocs("setup.gen")
        toOut &= con4mRuntime.getCommandDocs("setup.load")
      of "commands":
        toOut &= con4mRuntime.getCommandDocs("")
      of "configuration", "configurations", "conffile", "configs", "conf":
        for section in allConfigVarSections:
          toOut &= con4mRuntime.getConfigOptionDocs(section)
      of "topics":
        toOut &= con4mRuntime.getHelpTopics()
      of "builtins":
        toOut = con4mRuntime.getBuiltinsTableDoc()
      else:
        let toCheck = [arg, "core-" & arg, "howto-" & arg, "guide" & arg]
        var gotIt = false

        for item in toCheck:
          if item in helpFiles:
            toOut &= helpFiles[arg].markdownToHtml().stylize()
            gotit = true
            break

        if gotIt == false:
          # If we see an unknown argument at any position, stop what
          # we were doing and run a full-text search on all passed
          # arguments.
          toOut = con4mRuntime.fullTextSearch(args)
          break

  if chalkConfig.getUsePager():
    runPager(toOut)
  else:
    echo toOut
  quit(0)

const
  docDir   = "chalk-docs"
  cmdline  = docDir.joinPath("command-line.md")
  conffile = docDir.joinPath("config-file.md")
  outconf  = docDir.joinPath("output-config.md")
  keyinfo  = docDir.joinPath("metadata.md")
  builtins = docDir.joinPath("builtins.md")

proc filterForCodecs(inarr: seq[seq[string]]): seq[seq[string]] =
  for row in inarr:
    if row[2] == "true":
      result.add(@[row[0], row[1], row[3], row[4], row[5]])

proc filterForPlugins(inarr: seq[seq[string]]): seq[seq[string]] =
  for row in inarr:
    if row[2] == "false":
      result.add(@[row[0], row[1], row[3], row[4], row[5]])

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

proc buildSinkConfigData(): seq[seq[string]] =
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
    result.add(@[key, config.mySink.getName(), paramFmt(config.params),
                   filterFmt(config.filters), sublists[config].join(", ")])

proc getConfigValues(): string =

  var
    configTables: OrderedTable[string, seq[seq[string]]]
  let
    state         = getChalkRuntime()
    cols          = [CcVarName, CcShort, CcCurValue]
    outConfFields = ["report_template", "mark_template"]
    cReportFields = ["enabled", "report_template", "use_when"]
    sinkCfgFields = ["sink", "filters"]
    plugFields    = ["enabled", "codec", "priority", "ignore", "overrides"]
    confHdrs      = ["Config Variable", "Description", "Current Value"]
    plugHdrs      = ["Name", "Enabled", "Priority", "Ignore", "Overrides"]
    outConHdrs    = ["Operation", "Reporting Template", "Chalk Mark Template"]
    custRepHdrs   = ["Name", "Enabled", "Template", "Operations where applied"]
    sinkHdrs      = ["Config Name", "Sink", "Parameters", "filters", "Topics"]

    fn            = getValuesForAllObjects
    outConfData   = fn(state, "outconf",       outConfFields, asLit = false)
    custRepData   = fn(state, "custom_report", cReportFields, asLit = false)
    allPluginData = fn(state, "plugin",        plugFields,    asLit = false)
    sinkCfgData   = buildSinkConfigData()
    codecData     = filterForCodecs(allPluginData)
    pluginData    = filterForPlugins(allPluginData)
    (coRows, coHdr) = codecData.filterEmptyColumns(plugHdrs)
    (piRows, piHdr) = pluginData.filterEmptyColumns(plugHdrs)

  for item in allConfigVarSections:
    configTables[item] = state.getMatchingConfigOptions(item, cols = cols,
                                                        sectionPath = item)
  for k, v in configTables:
    if len(v) == 0 or len(v[0]) == 0:
      continue

    if k == "":
      result &= "<h1>Global configuration variables</h1>"
    else:
      result &= "<h1>Config variables in the '" & k & "' section</h1>"

    result &= v.formatCellsAsHtmlTable(confHdrs)

  result &= "<h1>Metadata template configuration</h1>"
  result &= outConfData.formatCellsAsHtmlTable(outConHdrs)

  result &= "<h1>Additional reports configured</h1>"
  result &= custRepData.formatCellsAsHtmlTable(custRepHdrs)

  result &= "<h1>I/O configuration</h1>"
  result &= sinkCfgData.formatCellsAsHtmlTable(sinkHdrs)

  result &= "<h1>Codecs</h1>"
  result &= coRows.formatCellsAsHtmlTable(coHdr)

  result &= "<h1>Additional Data Collectors</h1>"
  result &= piRows.formatCellsAsHtmlTable(piHdr)

proc showConfigValues*(force = false) =
  once:
    if not (chalkConfig.getShowConfig() or force): return

    let toOut = getConfigValues().stylize()

    if chalkConfig.getUsePager():
      runPager(toOut)
    else:
      echo toOut

proc runChalkDocGen*() =
  var
    f: FileStream
    con4mRuntime = getChalkRuntime()
    opts         = CmdLineDocOpts(docKind: CDocRaw)

  # 1. Dump embedded markdown docs.
  createDir(docDir)
  for k, v in helpFiles:
    f = newFileStream(docDir.joinPath(k) & ".md", fmWrite)
    f.write(v)
    f.close()

  # 2. Write out command docs.
  f = newFileStream(cmdline, fmWrite)
  for item in allCommandSections:
    f.write(con4mRuntime.getCommandDocs(item, opts))
  f.close()

  # 3. Write out the configuration file docs.
  f = newFileStream(conffile, fmWrite)
  for section in allConfigVarSections:
    f.write(con4mRuntime.getConfigOptionDocs(section, CDocRaw,
                                             expandDocField = false))
  f.close()

  # 4. Write out the output config doc.
  f = newFileStream(outconf, fmWrite)
  f.write(con4mRuntime.getOutputHelp(CDocRaw))
  f.close()

  # 5. The metadata reference
  f = newFileStream(keyinfo, fmWrite)
  f.write(con4mRuntime.keyHelp(docKind = CDocRaw))
  f.close()

  # 6. Output the reference on config builtins.
  f = newFileStream(builtins, fmWrite)
  f.write(con4mRuntime.getBuiltinsTableDoc(docKind = CDocRaw))
  f.close()
