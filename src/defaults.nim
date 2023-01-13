import tables, options, strutils, strformat, unicode
import nimutils, config, builtins

proc formatTitle(text: string): string {.inline.} =
  let
    titleCode = toAnsiCode(@[acFont4, acBGreen])
    endCode   = toAnsiCode(@[acReset])

  return titleCode & text & endCode & "\n"

const
    hdrFmt      = @[acFont2, acBCyan]
    evenFmt     = @[acFont0, acBGCyan, acBBlack]
    oddFmt      = @[acFont0, acBGWhite, acBBlack]

proc samiTableFormatter*(numColumns: int): TextTable =
  return newTextTable(numColumns      = numColumns,
                      colHeaderSep    = some(Rune('|')),
                      colSep          = some(Rune('|')),
                      rowHeaderSep    = some(Rune('-')),
                      intersectionSep = some(Rune('+')),
                      rHdrFmt         = hdrFmt,
                      eRowFmt         = evenFmt,
                      oRowFmt         = oddFmt,
                      addLeftBorder   = true,
                      addRightBorder  = true,
                      addTopBorder    = true,
                      addBottomBorder = true,
                      headerRowAlign  = some(AlignCenter),
                      wrapByDefault   = true,
                      maxCellBytes    = 200)

proc showGeneralOptions*(): int {.discardable.} =
  # Returns the width of the table.
  var ot = samiTableFormatter(3)

  ot.addRow(@["Option", "Value", "Con4m Variable"])
  ot.addRow(@["Color",                $(getColor()), "color"])
  ot.addRow(@["Log level",            $(getLogLevel()), "log_level"])
  ot.addRow(@["Dry run",              $(getDryRun()), "dry_run"])
  
  ot.addRow(@["Config files allowed", $(getAllowExternalConfig()),
              "allow_external_config"])
  ot.addRow(@["Export builtin config ok", $(getCanDump()), "can_dump"])
  ot.addRow(@["Replace builtin config ok", $(getCanLoad()), "can_load"])
  ot.addRow(@["Artifact search path", getArtifactSearchPath().join(", "),
              "artifact_search_path"])
  ot.addRow(@["Recurse for artifacts", $(getRecursive()), "recursive"])
  # default_command is not implemented, but add it when it is.
  
  if getAllowExternalConfig():
    ot.addRow(@["Config file path",
                getConfigPath().join(", "),
                "config_path"])
    ot.addRow(@["Config file name", $(getConfigFileName()),
                                      "config_filename"])

  let tableout = ot.render()
  publish("defaults", formatTitle("General Options:") & tableout)
  return tableout.find("\n")

proc paramFmt(t: StringTable): string =
  var parts: seq[string] = @[]

  for key, val in t:
    if key == "secret":
      parts.add(key & " : " & "(redacted)")
    else:
      parts.add(key & " : " & val)

  return parts.join(", ")

proc filterFmt(flist: seq[MsgFilter]): string =
  var parts: seq[string] = @[]
  
  for filter in flist:
    parts.add(filter.getFilterName().get())

  return parts.join(", ")

proc showSinkConfigs*(): int {.discardable.} =
  var
    sinkConfigs = getSinkConfigs()
    ot          = samiTableFormatter(5)
    subLists:     Table[SinkConfig, seq[string]]
    unusedTopics: seq[string]

  for topic, obj in allTopics:
    if len(obj.subscribers) == 0:
      unusedTopics.add(topic)
    for config in obj.subscribers:
      if config notin subLists:
        subLists[config] = @[topic]
      else:
        subLists[config].add(topic)
  
  ot.addRow(@["Config name", "Sink", "Parameters", "Filters", "Topics"])
  for key, config in sinkConfigs:
    if config notin sublists:
      sublists[config] = @[]
    ot.addRow(@[key,
                config.mySink.getSinkName(),
                paramFmt(config.config),
                filterFmt(config.filters),
                sublists[config].join(", ")
    ])

  let specs       = ot.getColSpecs()
  specs[2].minChr = 15
  
  let tableout = ot.render()
  publish("defaults", formatTitle("Output Configuration:") & tableout)
  if len(unusedTopics) != 0 and getLogLevel() == llTrace:
    let unused = unusedTopics.join(", ")
    publish("defaults", formatTitle(fmt"Unused topics: {unused}") & "\n")
      
  return tableout.find("\n")

proc showKeyConfigs*(): int {.discardable.} =
  # required
  # value
  # In reference
  # skip
  # description
  var
    keyList  = getOrderedKeys()
    custom   = getCustomKeys()
    ot       = samiTableFormatter(5)
  let
    sysVal   = pack("*provided by system*")
    emptyVal = pack("*supplied via plugin*")

  ot.addRow(@["Key", "Use", "Value", "In Ptr?", "Description"])
  
  for key in keyList:
    if key in custom: continue
    let
      spec    = getKeySpec(key).get()
      enabled = if spec.getSkip(): "NO" else: "yes"
      system  = spec.getSystem()
      defOpt  = spec.getValue()
      default = $(getOrElse(defOpt, if system: sysVal else: emptyVal))
      inRef   = if spec.getInRef(): "YES" else: "no"
      desc    = getOrElse(spec.getDocString(), "none")

    ot.addRow(@[key, enabled, default, inRef, desc])

  if len(custom) != 0:
    # TODO... Span rows and/or per-cell overrides.  Tmp hack.
    ot.addRow(@[":", "    ", "", "", ""]) 
    ot.addRow(@["CUSTOM KEYS:", "", "", "", ""]) 

    for key in custom: 
      let
        spec    = getKeySpec(key).get()
        enabled = if spec.getSkip(): "NO" else: "yes"
        defOpt  = spec.getValue()
        default = $(getOrElse(defOpt, pack("none")))
        inRef   = if spec.getInRef(): "YES" else: "no"
        desc    = getOrElse(spec.getDocString(), "none")

      ot.addRow(@[key, enabled, default, inRef, desc])
  
  let tableout = ot.render()
  publish("defaults", formatTitle("SAMI Key Configuration:") & tableout)

  return tableout.find("\n")
               
proc showDisclaimer*(w: int) =
  var disclaimer = "Note that these values can change based on logic in " &
                      "the config file.  You can cause the current " &
                      " configuration to be published to the 'defaults' " &
                      "topic on any run by setting 'publish_defaults' in " &
                      "the con4m configuration or passing " &
                      "'--publish-defaults' on the command line.\n\n" &
                      "Note that '--no-publish-defaults' at the command " &
                      "line will block this feature, even if the " &
                      "configuration file asks for it to be used. Running " &
                      "the 'defaults' command always publishes, though."
  publish("defaults", "\n" & indentWrap(disclaimer, w - 1) & "\n")
  
proc showConfig*(viaCmd: bool) =
  
  showGeneralOptions()
  showSinkConfigs()
  let w = showKeyConfigs()
  if viaCmd:
    showDisclaimer(w)
      
