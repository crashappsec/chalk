##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk help` command.

import ../config

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

proc showCommandHelp*(cmd = getCommandName()) {.noreturn.} =
  let spec = getArgCmdSpec()

  publish("help", getCmdHelp(getArgCmdSpec(), getArgs()))

  quit(0)

proc runChalkHelp*(cmdName: string) {.noreturn.} =
  var
    output: string = ""
    filter: Con4mRowFilter = nil
    args = getArgs()

  case cmdName
  of "help":
    output = getAutoHelp()
    if output == "":
      var mySpec = getArgCmdSpec()

      # We dont actually want the help docs for "chalk help", we
      # want the help for "chalk"
      if mySpec.parent.isSome():
        mySpec = mySpec.parent.get()

      output = getCmdHelp(myspec , args)
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
     "help.profile", "help.custom_report":
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
     "help.key.props", "help.profile.props":
       cmdName.noExtraArgs()
       let name = cmdName.split(".")[^2]
       output &= "Important Properties: \n"
       output &= getChalkRuntime().spec.get().oneObjTypeToTable(name)

  of "help.sbom", "help.sast":
    let name       = cmdName.split(".")[^1]
    let toolFilter = if name == "sbom": filterBySbom else: filterBySast

    if chalkConfig.tools == nil or len(chalkConfig.tools) == 0:
      output = "No tools configured."
    elif len(args) == 0:
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
  of "help.builtins":
    var
      rawBiDocs = unpack[string](c4mFuncDocDump(@[], getChalkRuntime()).get())
      allDocs   = rawBiDocs.parseJson()

    var toShow: JSonNode

    if len(args) == 0:
      toShow = allDocs
    else:
      toShow = newJObject()

      for k, obj in allDocs.mpairs():
        var added = false

        if "doc" notin obj:
          continue
        if "tags" in obj:
          let tags = to(obj["tags"], seq[string])
          for tag in tags:
            if tag in args:
              toShow[k] = obj
              added     = true
              break
          if added:
            continue
          # parts[0] will be the name of the function.
          let parts = k.split("(")
          if parts[0] in args:
            toShow[k] = obj
            continue
          let docstr = to(obj["doc"], string)
          for item in args:
            if item in docstr:
              toShow[k] = obj
              break
    if len(toShow) == 0:
      output = "No builtin functions matched your search terms.\n" &
               "Run 'chalk help builtins' to see all functions with no args.\n"
    else:
      var rows = @[@["Function", "Categories", "Documentation"]]

      for k, obj in toShow.mpairs():
        if "doc" notin obj: continue
        let
          doc  = to(obj["doc"], string)
          tags = if "tags" in obj: to(obj["tags"], seq[string]) else: @[]
        rows.add(@[k, tags.join(", "), doc])

      var table = tableC4mStyle(3, rows=rows)
      output = table.render() & "\n"

    if len(args) == 0:
      output &= "\nTip: you can add search terms to filter the above list."
  else:
    if not cmdName.endsWith(".help"):
      output = "Unknown command: " & cmdName
    # Otherwise; we got auto-helped.

  if len(output) == 0 or output[^1] != '\n': output &= "\n"

  publish("help", output)
  quit()

proc runChalkHelp*() {.noreturn.} = runChalkHelp("help")
