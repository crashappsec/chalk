##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk help` command.

import ../config, std/terminal

const helpFiles = newFileTable("../docs/")

# This one should be gotten via API call, not hardcoded.
const allConfigVarSections = ["", "docker", "exec", "extract", "env_config",
                              "source_marks"]

# Same here, should generate via API.
const allCommandSections = ["", "insert", "docker", "extract", "extract.images",
                            "extract.containers", "extract.all", "exec",
                            "setup", "setup.gen", "setup.load", "env",
                            "defaults", "dump", "load", "delete", "version"]

# template dbug(a, b) = print("<jazzberry>" & a & ": </jazzberry>" & b)

proc showCommandHelp*(cmd = getCommandName()) {.noreturn.} =
  let spec = getArgCmdSpec()

  publish("help", getCmdHelp(getArgCmdSpec(), getArgs()))

  quit(0)

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


  if docKind == CDocRaw:
    mdFields = @[]

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

proc highlightMatchesMd(s: string, terms: seq[string]): string =
  result = s
  for term in terms:
    result = result.replace(term, "**" & term & "**")

proc searchEmbeddedDocs(terms: seq[string]): string =
  # Terminal only.
  for key, doc in helpfiles:
    var matchedTerms: seq[string] = @[]

    for term in terms:
      if term in doc:
        matchedTerms.add(term)

    if len(matchedTerms) != 0:
      result &= "<h2>Match on document: " & key & "</h2>"
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
  # - Search profiles.
  # - Search developer docs.


proc getHelpTopics(state: ConfigState): string =
  result &= "<h1>Additional help topics </h1>"
  result &= "<h2>Use `chalk help <topicname>` to read</h2>"
  result &= "<ul>"

  for k, _ in helpFiles:
    result &= "<li>" & k & "</li>"

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

proc getProfileHelp(state: ConfigState, args: seq[string]): string =
  if len(args) == 0:
    result= """<h1>Available profiles </h1>
You can see what each of the below profiles sets with `chalk help profile "name"`.

See `chalk help reporting` for more information on reporting.
"""
    result &= state.getAllInstanceDocs("profile",["shortdoc"],
                                       ["Profile Name", "Description"])
  else:
    var profiles: seq[string]

    if "all" in args:
      for k, v in chalkConfig.profiles:
        profiles.add(k)
    else:
      for item in args:
        if item notin chalkConfig.profiles:
          result &= "<h3>Profile not found: " & item & "<h3>"
        else:
          profiles.add(item)

    if len(profiles) == 0:
      result &= "<h1>No matching profiles found.</h1>"
      return

    for profile in profiles:
      result &= "<h1>Profile: " & profile & "</h1>"

      var
        keysToReport: seq[string]
        theProfile = chalkConfig.profiles[profile]
        profileDoc = theProfile.doc.getOrElse("No description available.")
        maxKeyLen  = 0
        numCols    = 1
        tw         = terminalWidth()

      result &= profileDoc

      if theProfile.enabled != true:
        result &= "<h3>Warning: Profile is disabled and must be enabled " &
          "before using</h3>"

      for k, v in theProfile.keys:
        if v.report == true:
          keysToReport.add(k)
          if len(k) > maxKeyLen:
            maxKeyLen = len(k)

      if len(keysToReport) == 0:
        result &= "<h2>This profile is empty, and will only report default " &
          "values </h2>"

      else:
        result &= "<h2>Keys this profile reports (beyond any required "&
          "defaults): </h2>"
        if tw > maxKeyLen:
          numCols = tw div (maxKeyLen + 1)

        result &= "<table><tbody><tr>"

        for i in 0 ..< len(keysToReport):
          result &= "<td>" & keysToReport[i] & "</td>"
          if (i + 1) mod numCols == 0:
            result &= "</tr>"
            if (i + 1) != len(keysToReport):
              result &= "<tr>"

        result &= "</tr></tbody></table><p><p>"

  result = result.stylize()

proc getOutputHelp(state: ConfigState, kind = CDocConsole): string =
  let
    (profshort, proflong) = state.getSectionDocs("profile", kind)
    (sconfsh, sconflong)  = state.getSectionDocs("sink_config", kind)
    (custshort, custlong) = state.getSectionDocs("custom_report", kind)

  result  = proflong
  result &= sconflong
  result &= custlong

  result &= state.getSinkHelp(kind)

  result = result.docFormat(kind)

proc runChalkHelp*(cmdName = "help") {.noreturn.} =
  var
    args         = getArgs()
    toOut        = ""
    con4mRuntime = getChalkRuntime()

  if cmdName != "help":
    if cmdName == "profile":
      toOut &= con4mRuntime.getProfileHelp(args)
    else:
      toOut = con4mRuntime.getCommandDocs(cmdName)
  elif len(args) == 0:
    toOut = con4mRuntime.getHelpOverview()
  elif args[0] in ["metadata", "keys"]:
      toOut = con4mRuntime.keyHelp(args)
  elif args[0] == "search":
    toOut = con4mRuntime.fullTextSearch(args[1 .. ^1])
  elif args[0] in ["profile", "profiles"]:
    toOut &= con4mRuntime.getProfileHelp(args[1 .. ^1])
  else:
    for arg in args:
      case arg
      of "output", "reports", "reporting":
        toOut &= con4mRuntime.getOutputHelp()
      of "plugins":
        toOut &= con4mRuntime.getPluginHelp()
      of "insert", "delete", "env", "dump", "load", "defaults",
         "version", "docker", "profile", "exec":
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
      of "config", "configs":
        for section in allConfigVarSections:
          toOut &= con4mRuntime.getConfigOptionDocs(section)
      of "topics":
        toOut &= con4mRuntime.getHelpTopics()
      of "builtins":
        toOut = con4mRuntime.getBuiltinsTableDoc()
      else:
        if arg in helpFiles:
          toOut &= helpFiles[arg].markdownToHtml().stylize()
        else:
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
