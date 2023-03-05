## This module implements both the "defaults" command, and the similar
## --publish-defaults functionality for other commands.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import tables, options, strutils, strformat, unicode
import nimutils, config, builtins

proc formatTitle*(text: string): string {.inline.} =
  let
    titleCode = toAnsiCode(@[acFont4, acBGreen])
    endCode   = toAnsiCode(@[acReset])

  return titleCode & text & endCode & "\n"

const
    hdrFmt*     = @[acFont2, acBCyan]
    evenFmt*    = @[acFont0, acBGCyan, acBBlack]
    oddFmt*     = @[acFont0, acBGWhite, acBBlack]

proc chalkTableFormatter*(numColumns:  int,
                         rows:        seq[seq[string]]      = @[],
                         headerAlign: Option[AlignmentType] = some(AlignCenter),
                         wrapStyle                          =  WrapBlock,
                         maxCellSz                          =  200): TextTable =
  return newTextTable(numColumns      = numColumns,
                      rows            = rows,
                      fillWidth       = true,
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
                      headerRowAlign  = headerAlign,
                      wrapStyle       = wrapStyle,
                      maxCellBytes    = maxCellSz)

template row(x, y, z: string) = ot.addRow(@[x, y, z])
proc showGeneralOptions*(): int {.discardable.} =
  # Returns the width of the table.
  var
    conf   = chalkConfig
    ot     = chalkTableFormatter(3)
    confOk = $(conf.getAllowExternalConfig())
    def    = conf.getDefaultCommand().getOrElse("none")
    path   = conf.getArtifactSearchPath().join(", ")

  row("Option", "Value", "Con4m Variable")
  row("Color",  $(conf.getColor().get()), "color")
  row("Log level", conf.getLogLevel(), "log_level")
  row("Don't modify artifacts", $(conf.getVirtualChalk()), "virtual_chalk")
  row("Allow config files", confOk, "allow_external_config")
  row("Export builtin config ok", $(conf.getCanDump()), "can_dump")
  row("Replace builtin config ok", $(conf.getCanLoad()), "can_load")
  row("Audit config on load", $(conf.getPublishAudit()), "publish_audit")
  row("Always publish defaults", $(conf.getPublishDefaults()),
      "publish_defaults")
  row("Ignore config errors", $(conf.getIgnoreBrokenConf()),
      "ignore_broken_conf")
  row("Artifact search path", path, "artifact_search_path")
  row("Recurse for artifacts", $(conf.getRecursive()), "recursive")
  row("Ignored patterns", conf.getIgnorePatterns().join(", "),
      "ignore_patterns")
  row("Default exe command",  def, "default_command")
  row("Container image hash", conf.getContainerImageId(), "container_image_id")
  row("Container Image name", conf.getContainerImageName,
      "container_image_name")
  if conf.getAllowExternalConfig():
    row("Config file path", conf.getConfigPath().join(", "), "config_path")
    row("Config file name", conf.getConfigFileName(), "config_filename")

  let tableout = ot.render()
  publish("defaults", formatTitle("General Options:") & tableout)
  return tableout.find("\n")

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

proc showSinkConfigs*(): int {.discardable.} =
  var
    sinkConfigs = getSinkConfigs()
    ot          = chalkTableFormatter(5)
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

  let tableout = ot.render()
  publish("defaults", formatTitle("Output Configuration:") & tableout)
  if len(unusedTopics) != 0 and getLogLevel() == llTrace:
    let unused = unusedTopics.join(", ")
    publish("defaults", formatTitle(fmt"Unused topics: {unused}") & "\n")

  return tableout.find("\n")

proc showKeyConfigs*(): int {.discardable.} =
  var
    keyList  = getOrderedKeys()
    custom   = getCustomKeys()
    ot       = chalkTableFormatter(5)
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
      inPtr   = if spec.getInPtr(): "YES" else: "no"
      desc    = getOrElse(spec.getDocString(), "none")

    ot.addRow(@[key, enabled, default, inPtr, desc])

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
        inPtr   = if spec.getInPtr(): "YES" else: "no"
        desc    = getOrElse(spec.getDocString(), "none")

      ot.addRow(@[key, enabled, default, inPtr, desc])

  let tableout = ot.render(-4)
  publish("defaults", formatTitle("Chalk Key Configuration:") & tableout)

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

proc showConfig*(force: bool = false) =
  once:
    if chalkConfig.getPublishDefaults() or force:
      showGeneralOptions()
      showSinkConfigs()
      let w = showKeyConfigs()
      if force: showDisclaimer(w)
