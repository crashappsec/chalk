import options, tables, strutils, strformat, nimutils, sugar, types, st, os,
       dollars

type
  CObjDocs* = object
    sectionDocs: OrderedTable[string, string]
    fieldInfo:   OrderedTable[string, OrderedTableRef[string, string]]

  FieldPropDocs*   = OrderedTableRef[string, string]
  ObjectFieldDocs* = OrderedTable[string, FieldPropDocs] # field name -> props
  SectionObjDocs*  = OrderedTable[string, ObjectFieldDocs] # obj name -> fields

  ConfigCols* = enum
    CcVarName, CcShort, CcLong, CcType, CcDefault, CcCurValue
  BuiltInCols* = enum
    BiSig, BiCategories, BiLong

  ## FieldTransformer takes a field name and value, and returns a new value
  FieldTransformer*  = (string, string) -> string
  TransformTableRef* = TableRef[string, FieldTransformer]

template noSpec() =
  raise newException(ValueError, "No spec found for field: " & path)

proc getSectionSpecOfFqn*(state: ConfigState, pathString: string):
                        Option[Con4mSectionType] =
  if state.spec.isNone():
    raise newException(ValueError, "No specs provided.")

  if pathString == "":
    return some(state.spec.get().rootSpec)

  var offset = 1 # len(parts) - ... to get to the name.
  let
    parts    = pathString.split(".")
    fieldOpt = getOpt[Box](state.attrs, pathString)

  if fieldOpt.isSome():
    offset += 1

  if len(parts) < offset:
    return none(Con4mSectionType)

  let singletonOrInstanceName = parts[len(parts) - offset]

  if singletonOrInstanceName in state.spec.get().secSpecs:
    return some(state.spec.get().secSpecs[singletonOrInstanceName])

  offset += 1

  if len(parts) < offset:
    return none(Con4mSectionType)

  let objName = parts[len(parts) - offset]

  if objName in state.spec.get().secSpecs:
    return some(state.spec.get().secSpecs[objName])
  else:
    return none(Con4mSectionType)

proc getFieldSpec*(state: ConfigState, path: string): FieldSpec =
  let specOpt = state.getSectionSpecOfFqn(path)

  if specOpt.isNone():
    noSpec()

  let
    name = path.split(".")[^1]
    spec = specOpt.get()

  if name notin spec.fields:
    noSpec()

  result = spec.fields[name]

proc extractFieldInfo*(finfo: FieldSpec): OrderedTableRef[string, string] =
  result = newOrderedTable[string, string]()

  let eType = finfo.extType
  case eType.kind
  of TypePrimitive, TypeC4TypeSpec:
    result["allowed_type"]  = $(eType.tInfo)
    if eType.range.low != eType.range.high or eType.range.low > 0:
      # This is used only for integers and is inclusive.
      result["min"] = $(eType.range.low)
      result["max"] = $(eType.range.high)
    elif eType.itemCount.low != eType.itemCount.high or eType.itemCount.low > 0:
      # This is used for lists.
      result["min"] = $(eType.itemCount.low)
      result["max"] = $(eType.itemCount.high)
    if len(eType.intChoices) != 0:
      result["choices"] = `$`(eType.intChoices)[1 .. ^1]
    elif len(eType.strChoices) != 0:
      result["choices"] = `$`(eType.strChoices)[1 .. ^1]
  of TypeC4TypePtr:
    result["provides_type_for"] = eType.fieldRef
  of TypeSection:
    discard

  if eType.validator != CallbackObj(nil):
    result["validator_name"] = eType.validator.name
    result["validator_type"] = $(eType.validator.tInfo)

  # Don't use this version... the spec sets the defult value for
  # lockOnWrite but it can be changed per-object.
  # result["write_lock"] = $(finfo.lock)
  result["default"]    = $(finfo.default.getOrElse(pack("<none>")))
  result["exclusions"] = finfo.exclusions.join(", ")
  result["longdoc"]    = finfo.doc.getOrElse("")
  result["shortdoc"]   = finfo.shortdoc.getOrElse("")
  result["hidden"]     = $(finfo.hidden)

  if finfo.minRequired == 0:
    result["required"] = "false"
  else:
    result["required"] = "true"

proc fillFromObj(obj: AttrScope, name: string,
                 info: FieldPropDocs) =
  let opt = obj.attrLookup([name], 0, vlExists)

  if opt.isA(AttrErr):
    info["is_set"] = "false"
    return

  let
    aOrS = opt.get(AttrOrSub)
    attr = aOrS.get(Attribute)

  if attr.override.isSome():
    let
      asBox = get[Box](attr.override)
      asStr = attr.tInfo.oneArgToString(asBox, lit = false)

    info["override_on"] = "true"
    info["value"]       = asStr
    info["is_set"]      = "true"
  elif attr.value.isSome():
    let
      asBox = get[Box](attr.value)
      asStr = attr.tInfo.oneArgToString(asBox, lit = false)

    info["override_on"] = "false"
    info["value"]       = asStr
    info["is_set"]      = "true"
  else:
    info["override_on"] = "false"
    info["is_set"]      = "false"

  info["type"]               = $(attr.tInfo)
  info["locked"]             = $(attr.locked)
  info["lock_on_next_write"] = $(attr.lockOnWrite)

proc getAllFieldInfoForObj*(state: ConfigState, path: string):
                          OrderedTable[string,
                                       OrderedTableRef[string, string]] =
  ## Returns all the field documentation for a specific
  ## 'object'.

  let
    secOpt = state.getSectionSpecOfFqn(path)
    objOpt = state.attrs.getObjectOpt(path)

  if objOpt.isNone():
    raise newException(ValueError, "No object found: " & path)

  if secOpt.isNone():
    raise newException(ValueError, "No spec found for: " & path)

  let
    obj     = objOpt.get()
    secSpec = secOpt.get()

  for k, v in secSpec.fields:
    if v.extType.kind == TypeSection:
      continue

    var fieldInfo = v.extractFieldInfo()

    obj.fillFromObj(k, fieldInfo)

    result[k] = fieldInfo

proc getObjectLevelDocs*(state: ConfigState, path: string):
                       OrderedTable[string, string] =
  ## This returns the sections docs for a particular fully dotted
  ## section (meaning, a fully dotted object).

  ## The "longdoc" and "shortdoc" keys are taken from the section's
  ## fields, and "metalong" and "metashort" are taken from any "doc"
  ## or "shortdoc" fields in the section's spec.

  var secSpec: Con4mSectionType

  let
    obj   = state.attrs.getObject(path)
    parts = path.split(".")
    specs = state.spec.get()

  result["longdoc"]  = getOpt[string](obj, "doc").getOrElse("")
  result["shortdoc"] = getOpt[string](obj, "shortdoc").getOrElse("")

  if path == "":
    return

  if (result["longdoc"] == "" and result["shortdoc"] == "") or len(parts) == 1:
    if parts[^1] in specs.secSpecs:
      secSpec = specs.secSpecs[parts[^1]]
    if not secSpec.singleton:
      secSpec = Con4mSectionType(nil)

  if secSpec == nil and len(parts) > 1:
    if parts[^2] in specs.secSpecs:
      secSpec = specs.secSpecs[parts[^2]]
      if secSpec.singleton:
        secSpec = Con4mSectionType(nil)

  if secSpec == Con4mSectionType(nil):
    result["metalong"]  = ""
    result["metashort"] = ""
  else:
    let
      mlong  = secSpec.doc.getOrElse("")
      mshort = secSpec.shortdoc.getOrElse("")

    result["metashort"] = mshort
    result["metalong"]  = mlong


proc getSectionDocs*(state: ConfigState, section: string): (Rope, Rope) =
  var
    sec:    Con4mSectionType
    mshort: Rope
    mlong:  Rope

  let specs = state.spec.get()

  if section == "":
    sec = specs.rootSpec
  else:
    sec = specs.secSpecs[section]

  if sec.shortDoc.isSome:
    mshort = text(sec.shortDoc.get(), pre = false)
  if sec.doc.isSome:
    mlong = markdown(sec.doc.get())

  return (mshort, mlong)

proc getAllSubScopes*(scope: AttrScope): OrderedTable[string, AttrScope] =
  for k, v in scope.contents:
    if v.isA(Attribute):
      continue
    result[k] = v.get(AttrScope)

proc getAllObjectDocs*(state: ConfigState, path: string): CObjDocs =
  result.sectionDocs = state.getObjectLevelDocs(path)
  result.fieldInfo   = state.getAllFieldInfoForObj(path)

proc formatCommandTable(obj:  AttrScope): Rope =
  var cells: seq[seq[Rope]] = @[@[atom("Command Name"), atom("Description")]]

  for k, v in obj.contents:
    var row: seq[Rope] = @[]

    let scope = v.get(AttrScope)
    row.add(atom(k))

    if "shortdoc" in scope.contents:
      let shortDoc = get[string](scope, "shortdoc")
      row.add(text(shortdoc, pre = false))
    else:
      row.add(em("None"))
    cells.add(row)

  result = quickTable(cells, class = "help")

proc formatFlag(flagname: string): Rope =
  if len(flagname) == 1:
    result = inlineCode("-" & flagname)
  else:
    result = inlineCode("--" & flagname)

proc formatAliases(scope: AttrScope, flagname: string,
                   defYes, defNo: seq[string]): Rope =
  var
    aliases:   seq[string]
    negators:  seq[string]
    formatted: seq[Rope]

  if "aliases" in scope.contents:
    aliases = get[seq[string]](scope, "aliases")
  elif "yes_aliases" in scope.contents:
    aliases = get[seq[string]](scope, "yes_aliases")

  if "no_aliases" in scope.contents:
    negators = get[seq[string]](scope, "no_aliases")

  if len(defYes) != 0:
    for item in defYes:
      aliases.add(item & "-" & flagname)

  if len(defNo) != 0:
    for item in defNo:
      negators.add(item & "-" & flagname)

  if len(aliases) != 0:
    for item in aliases:
      formatted.add(item.formatFlag())
    result += paragraph(em("Aliases:") + text(" ") +
                        formatted.join(atom(", ")))
    formatted = @[]

  if len(negators) != 0:
    for item in negators:
      formatted.add(item.formatFlag())
    result += paragraph(em("Negated by:") + text(" ") +
                        formatted.join(atom(", ")))

proc baseFlag(flagname: string, scope: AttrScope, extraCol1, extraCol2: Rope,
              defYes: seq[string] = @[], defNo: seq[string] = @[]):
                                                      (Rope, Rope) =
  var
    left:  Rope
    right: Rope

  left += flagName.formatFlag()
  left += scope.formatAliases(flagname, defYes, defNo)
  if extraCol1 != nil:
    left += paragraph(extraCol1)

  if "doc" in scope.contents:
    right = paragraph(markdown(get[string](scope, "doc")))
  else:
    right = paragraph(atom("No description available."))

  if "field_to_set" in scope.contents:
    right += paragraph(em("Sets config field:") +
                         inlineCode(" " & get[string](scope, "field_to_set")))
  if extraCol2 != nil:
    right += paragraph(extraCol2)

  return (paragraph(left), right)

proc formatYnFlags(scope: AttrScope,
                   defaultYes, defaultNo: seq[string]): seq[seq[Rope]] =
  for k, v in scope.contents:
    let
      subscope = v.get(AttrScope)
      (l, r)   = k.baseFlag(subscope, nil, nil, defaultYes, defaultNo)
    result.add(@[l, r])

const
  reqArg      = "Flag requires an argument"
  reqArgMulti = "Flag can be a comma-separated list, or provided multiple times"

proc formatArgFlags(scope: AttrScope): seq[seq[Rope]] =
  for k, v in scope.contents:
    let
      subscope = v.get(AttrScope)
      (l, r)   =  k.baseFlag(subscope, nil, atom(reqArg))
    result.add(@[l, r])

proc formatMultiArgFlags(scope: AttrScope): seq[seq[Rope]] =
  for k, v in scope.contents:
    let
      subscope = v.get(AttrScope)
      (l, r)   = k.baseFlag(subscope, nil, atom(reqArgMulti))
    result.add(@[l, r])

proc formatChoiceFlags(scope: AttrScope, multi = false): seq[seq[Rope]] =
  var
    choices:    seq[string]
    rchoices:   seq[Rope]
    flag:       bool # flag for adding per-choice flags.
    left:       Rope
    right:      Rope

  for k, v in scope.contents:
    let subscope = v.get(AttrScope)
    choices    = get[seq[string]](subscope, "choices")
    flag       = getOpt[bool](subscope, "add_choice_flags").getOrElse(false)
    rchoices   = @[]

    if flag:
      for item in choices:
        rchoices.add(item.formatFlag())
      left = paragraph(strong("Per-choice alias flags:") +  atom(" ") +
                       rchoices.join(atom(", ")))

    rchoices = @[]

    for item in choices:
      rchoices.add(em(item))
    left += paragraph(strong("Value choices:") + atom(" ") +
                      rchoices.join(atom(", ")))

    if multi:
      right += paragraph(em("Multiple arguments may be provided."))

    if flag:
      right += paragraph(em("Flag requires an argument") +
                         atom(" (does not apply to per-choice aliases)"))
    elif not multi:
      right += paragraph(em("Flag requires an argument."))

    let (l, r) = k.baseFlag(subscope, nil, nil)

    result.add(@[@[l + left, r + right]])

proc formatMultiChoiceFlags(scope: AttrScope): seq[seq[Rope]] =
   return scope.formatChoiceFlags(true)

proc formatAutoHelpFlag(): seq[Rope] =
  result.add(paragraph(formatFlag("help") + paragraph(
                        strong("Aliases:") + atom(" ") + formatFlag("h"))))
  result.add(atom("Shows help for this command."))

proc formatFlags(obj: AttrScope, subsects: OrderedTable[string, AttrScope],
                 defaultYes: seq[string], defaultNo: seq[string]): Rope =
  var
    cells: seq[seq[Rope]] = @[@[th("Flag Name"), th("Description")]]

  if "flag_yn" in subsects:
    cells &= subsects["flag_yn"].formatYnFlags(defaultYes, defaultNo)
  if "flag_arg" in subsects:
    cells &= subsects["flag_arg"].formatArgFlags()
  if "flag_multi_arg" in subsects:
    cells &= subsects["flag_multi_arg"].formatMultiArgFlags()
  if "flag_choice" in subsects:
    cells &= subsects["flag_choice"].formatChoiceFlags()
  if "flag_multi_choice" in subsects:
    cells &= subsects["flag_multi_choice"].formatMultiChoiceFlags()
  if "flag_help" in subsects:
    cells.add(formatAutoHelpFlag())

  if len(cells) > 1:
    result = quicktable(cells, title = atom("Flags"), class = "help")
    let
      table = result.searchOne(@["table"]).get()
      even  = styleMap["tr.even"]
      odd   = styleMap["tr.odd"]

    for i, item in table.tbody.cells:
      if i == 0:
        continue
      if i mod 2 == 0:
        for tr in item.search(@["tr"]):
          tr.ropeStyle(even, recurse=true)
      else:
        for tr in item.search(@["tr"]):
          tr.ropeStyle(odd, recurse=true)

proc formatProps(obj: AttrScope, cmd: string, table: bool): Rope =
  var cells: seq[seq[Rope]]

  let
    aliasOpts = getOpt[seq[string]](obj, "aliases")
    argOpts   = getOpt[seq[Box]](obj, "args")

  if aliasOpts.isSome() and aliasOpts.get().len() != 0:
    var aliases = aliasOpts.get()
    var fmtAliases: Rope

    for i, item in aliasOpts.get():
      if i != 0:
        fmtAliases = fmtAliases.link(atom(", ") + em(item))
      else:
        fmtAliases = em(item)

    cells.add(@[text("Aliases"), fmtAliases])
  else:
    cells.add(@[text("Aliases"), em("None")])


  if argOpts.isNone():
    cells.add(@[text("Arguments"), em("None")])
  else:
    let
      vals = argOpts.get() # Will contain 2 items.
      vmin = unpack[int](vals[0])
      vmax = unpack[int](vals[1])

    if vmin == vmax:
      if vmin == 0:
        cells.add(@[text("Arguments"), em("None")])
      else:
        cells.add(@[text("Arguments"), text(`$`(vmin) & " (exactly)")])
    elif vmax > (1 shl 32):
      case vmin
      of 0:
        cells.add(@[text("Arguments"), text("Not required; any number okay")])
      else:
        cells.add(@[text("Arguments"), text(`$`(vmin) &
                                                 " required; more allowed")])
    else:
      cells.add(@[text("Arguments"), text(`$`(vmin) & " to " & `$`(vmax))])

  if len(cells) != 0:
    if table:
      result = quickTable(cells, noheaders = true, class = "help")
    else:
      var listItems: seq[Rope]
      for item in cells:
        listItems.add(li(strong(item[0]) + atom(": ") + item[1]))
      result = ul(listItems)

proc getHelpOverview*(state: ConfigState): Rope =
  try:
    let
      attrPath = "getopts.command.help"
      obj      = state.attrs.getObject(attrPath)
      objDocs  = state.getAllObjectDocs(attrPath)
      short    = objDocs.sectionDocs["shortdoc"]
      long     = objDocs.sectionDocs["longdoc"]


    result = h1(getMyAppPath().splitPath().tail)
    if short != "":
      result += h2(short)

    result += markdown(long)
  except:
    return h1("Please provide a 'help' command to get this to work.")

proc getCommandNonFlagData*(state: ConfigState, commandList: openarray[string],
                           filterTerms: openarray[string] = [],
                           baseGetoptPath = "getopts"): Rope =

  var cells: seq[seq[Rope]]

  for commandPath in commandList:
    var attrPath = baseGetoptPath
    for item in commandPath.split("."):
      attrPath &= ".command"
      if item != "":
        attrPath &= "." & item

    let
      obj      = state.attrs.getObject(attrPath)
      objDocs  = state.getAllObjectDocs(attrPath)
      short    = objDocs.sectionDocs["shortdoc"]
      long     = objDocs.sectionDocs["longdoc"]

    if len(filterTerms) != 0:
      var includeMe = false

      for term in filterTerms:
        if term in short or term in long:
          includeMe = true
          break
      if not includeMe:
        continue

    var thisRow = @[atom(commandPath), text(short, pre = false),
                    markdown(long)]
    let
      aliasOpts = getOpt[seq[string]](obj, "aliases")
      aliases   = aliasOpts.getOrElse(@[])
      argOpts   = getOpt[seq[Box]](obj, "args")

    thisRow.add(atom(aliases.join(", ")))

    if argOpts.isNone():
      thisRow.add(atom(""))

    else:
      let
        vals = argOpts.get() # Will contain 2 items.
        vmin = unpack[int](vals[0])
        vmax = unpack[int](vals[1])

      if vmin == vmax:
        if vmin == 0:
          thisRow.add(em("None"))
        else:
          thisRow.add(atom($(vmin) & " (exactly)"))
      elif vmax > (1 shl 32):
        case vmin
        of 0:
          thisRow.add(atom("not required; any number okay"))
        else:
          thisRow.add(atom($(vmin) & " required; more allowed"))
      else:
        thisRow.add(atom($(vmin) & " to " & $(vmax)))

    cells.add(thisRow)

  if len(cells) != 0:
    result = quickTable(cells, noheaders = true, class = "help")

type
  FlagDoc* = object
    flagName*:    string
    yesAliases*:  seq[string]
    noAliases*:   seq[string]
    kind*:        string
    doc*:         string
    sets*:        string      # What field the flag sets.
    argRequired*: bool
    multiArg*:    bool
    choices*:     seq[string]
    autoFlags*:   bool        # Whether choices were auto-flagged.

proc getYesAliases(scope: AttrScope, flagname: string,
                    defYes: openarray[string]): seq[string] =

  if "aliases" in scope.contents:
    result = get[seq[string]](scope, "aliases")
  elif "yes_aliases" in scope.contents:
    result = get[seq[string]](scope, "yes_aliases")

  if len(defYes) != 0:
    for item in defYes:
      result.add(item & "-" & flagName)

proc getNoAliases(scope: AttrScope, flagname: string,
                  defNo: openarray[string]): seq[string] =
  if "no_aliases" in scope.contents:
    result = get[seq[string]](scope, "no_aliases")

  if len(defNo) != 0:
    for item in defNo:
      result.add(item & "-" & flagName)

proc getOneFlagInfo(scope: AttrScope, flagname: string,
                    kind: string,
                    defYes: openarray[string] = [],
                    defNo: openarray[string] = []): FlagDoc =

  result.yesAliases = scope.getYesAliases(flagName, defYes)
  result.noAliases  = scope.getNoAliases(flagName, defNo)
  result.kind       = kind

  if len(flagname) == 1:
    result.flagName = "-" & flagname
  else:
    result.flagName = "--" & flagname

  if "doc" in scope.contents:
    result.doc = get[string](scope, "doc")

  if "field_to_set" in scope.contents:
    result.sets = get[string](scope, "field_to_set")

  if "choices" in scope.contents:
    result.choices   = get[seq[string]](scope, "choices")
    result.autoFlags = getOpt[bool](scope, "add_choice_flags").
                            getOrElse(false)

proc getAllCommandFlagInfo(state: ConfigState, command: string,
                           baseGetoptPath = "getopts"): seq[FlagDoc] =
  var attrPath = baseGetoptPath
  for item in command.split("."):
    if item != "":
      attrPath &= ".command." & item

  let
    obj        = state.attrs.getObject(attrPath)
    subsects   = obj.getAllSubScopes()
    yesAttr    = baseGetoptPath & ".default_yes_prefixes"
    noAttr     = baseGetoptPath & ".default_yes_prefixes"
    defaultYes = getOpt[seq[string]](state.attrs, yesAttr).getOrElse(@[])
    defaultNo  = getOpt[seq[string]](state.attrs, noAttr).getOrElse(@[])

  if "flag_yn" in subsects:
    for k, v in subsects["flag_yn"].contents:
      result.add(v.get(AttrScope).getOneFlagInfo(k, "boolean",
                                                 defaultYes, defaultNo))

  if "flag_arg" in subsects:
    for k, v in subsects["flag_arg"].contents:
      var toAdd         = v.get(AttrScope).getOneFlagInfo(k, "arg",
[], [])
      toAdd.argRequired = true
      result.add(toAdd)

  if "flag_multi_arg" in subsects:
    for k, v in subsects["flag_multi_arg"].contents:
      var toAdd      = v.get(AttrScope).getOneFlagInfo(k, "multi-arg",
[], [])
      toAdd.multiArg = true
      result.add(toAdd)

  if "flag_choice" in subsects:
    for k, v in subsects["flag_choice"].contents:
      result.add(v.get(AttrScope).getOneFlagInfo(k, "choice", [], []))

  if "flag_multi_choice" in subsects:
    for k, v in subsects["flag_multi_choice"].contents:
      var
        subscope = v.get(AttrScope)
        toAdd    = subscope.getOneFlagInfo(k, "multi-choice", [], [])
      toAdd.multiArg = true
      result.add(toAdd)

proc getCommandFlagInfo*(state: ConfigState, command: string,
                         filterTerms: openarray[string] = [],
                         baseGetoptPath = "getopts"): seq[FlagDoc] =
  let preResult = state.getAllCommandFlagInfo(command, baseGetoptPath)

  for item in preResult:
    var addIt: bool
    for term in filterTerms:
      if addIt: break
      if term in item.flagName or term in item.yesAliases or
         term in item.noAliases or term in item.doc or term in item.sets:
        addIt = true
        break
      for choice in item.choices:
        if term in choice:
          addIt = true
          break
    if addIt:
      result.add(item)
      break

proc getCommandDocs*(state: ConfigState, cmd: string, table = true,
                     noteEmptySubs = false): Rope =
  # This should explicitly test for the section existing.  Right now it'll
  # throw an error when it doesn't.
  var
    attrPath: string = "getopts"
    cells:    seq[seq[Rope]]

  if cmd != "":
    for item in cmd.split("."):
      attrPath &= ".command." & item

  let
    obj      = state.attrs.getObject(attrPath)
    objDocs  = state.getAllObjectDocs(attrPath)
    subsects = obj.getAllSubScopes()
    short    = objDocs.sectionDocs["shortdoc"]
    long     = objDocs.sectionDocs["longdoc"]
    subCmd   = if '.' in cmd: true else: false

  if cmd != "":
    if subCmd:
      result = h1(cmd & " subcommand")
    else:
      result = h1(cmd & " command")
  else:
    result = h1(getMyAppPath().splitPath().tail)

  if short != "":
    result += h2(short)

  if cmd != "":
    result += obj.formatProps(cmd, table = table)

  result += h3("Description")
  if long != "":
    result += markdown(long)
  else:
    result += atom("""
This is the default documentation for your command. If you'd like to
change it, set the 'shortdoc' field to set the title, and the 'doc'
field to edit this description.  You can use Markdown with embedded
HTML, and it will get rendered appropriately, whether at the command
line, or in generated HTML docs.
""")

  if "command" notin subsects:
    if noteEmptySubs:
        result += h3(atom("Subcommands: ") + em("None"))
  else:
    result += subsects["command"].formatCommandTable()

  let
    yesAttr    = "getopts.default_yes_prefixes"
    noAttr     = "getopts.default_no_prefixes"
    defaultYes = getOpt[seq[string]](state.attrs, yesAttr).getOrElse(@[])
    defaultNo  = getOpt[seq[string]](state.attrs, noAttr).getOrElse(@[])

  result += obj.formatFlags(subsects, defaultYes, defaultNo)

proc extractSectionFields(sec: Con4mSectionType, showHidden = false,
                          skipTypeSpecs = false, skipTypePtrs = false):
                         OrderedTable[string, FieldSpec] =
  # This only pulls out actual fields; the dictionary also has any
  # sub-sections that are acceptable.
  for n, spec in sec.fields:
    if spec.hidden and not showHidden:
      continue
    case spec.extType.kind
    of TypeSection:
      continue
    of TypeC4TypeSpec:
      if skipTypeSpecs:
        continue
    of TypeC4TypePtr:
      if skipTypePtrs:
        continue
    of TypePrimitive:
      discard

    result[n] = spec

proc getMatchingConfigOptions*(state: ConfigState,
                               section                        = "",
                               title                          = "",
                               showHiddenFields               = false,
                               headings: openarray[string]    = [],
                               filterTerms: openarray[string] = [],
                               cols: openarray[ConfigCols]    =
                                     [CcVarName, CcType, CcDefault, CcLong],
                               sectionPath = ""): Rope =
  # SectionPath is only needed if you request CcCurValue
  if state.spec.isNone():
    return

  var
    sec:   Con4mSectionType
    cells: seq[seq[Rope]]

  if headings.len() != 0:
    var row: seq[Rope]
    for item in headings:
      row.add(th(item))
    cells.add(row)

  if section == "":
    sec = state.spec.get().rootSpec
  else:
    let secspecs = state.spec.get().secSpecs

    if section notin secspecs:
      return

    sec = secspecs[section]

  let fieldsToShow = sec.extractSectionFields(showHidden = showHiddenFields)
  if len(fieldsToShow) == 0:
    return

  for n, f in fieldsToShow:
    var
      thisRow: seq[Rope] = @[]
      showRow: bool = false

    for item in cols:
      case item
      of CcVarName:
        thisRow.add(atom(n))
      of CcCurValue:
        var path: string
        if sectionPath == "":
          path = n
        else:
          path = sectionPath & "." & n

        let objOpt = getOpt[Box](state.attrs, path)
        if objOpt.isNone():
          thisRow.add(em("None"))
        else:
          let
            obj = objOpt.get()
            s   = f.extType.tInfo.oneArgToString(obj, lit = true)
          thisRow.add(inlineCode(s))
      of CcShort:
        thisRow.add(text(f.shortDoc.getOrElse("No description available."),
                         pre = false))
      of CcLong:
        thisRow.add(markdown(f.doc.getOrElse(
                  "There is no documentation for this option.")))
      of CcType:
        case f.extType.kind:
          of TypeC4TypePtr:
            thisRow.add(atom("Type set by field ") + em(f.extType.fieldRef))
          of TypeC4TypeSpec:
            thisRow.add(atom("A type specification"))
          of TypePrimitive:
            thisRow.add(atom($(f.extType.tInfo)))
          else:
            discard
      of CcDefault:
        if f.default.isSome():
          thisRow.add(inlineCode(
            f.extType.tInfo.oneArgToString(f.default.get(), lit = true)))
        else:
          thisRow.add(em("None"))

    if len(filterTerms) == 0:
      showRow = true
    elif not showRow and filterTerms.len() > 0:
      for item in thisRow:
        if item.search(text = filterTerms).len() > 0:
          showRow = true
          break

    if showRow:
      cells.add(thisRow)

  if len(cells) != 0:
    var noheaders = if headings.len() == 0: false else: true

    result = quickTable(cells, title = title, noheaders = noheaders,
                                       class = "help")

proc getConfigOptionDocs*(state: ConfigState,
            secName                     = "",
            showHiddenSections          = false,
            showHiddenFields            = false,
            expandDocField              = true,
            cols: openarray[ConfigCols] = [CcVarName, CcType,
                                           CcDefault, CcLong],
            colNames: openarray[string] = ["Variable", "Type",
                                           "Default Value", "Description"],
            secVarHeader = "Section configuration variables"): Rope =
  ## This returns a document with a single 'section' of configuration
  ## variables.
  ##
  ## The section name you pass in ideally would be a 'singleton'
  ## section in the TOP-LEVEL root scope.  Singleton sections in other
  ## named sections feel more like object data than configuration.
  ##
  ## We do not look these up by path, we go straight to the specs for
  ## the various sections, and we do ensure that it's a singleton.

  if state.spec.isNone():
    return nil

  var
    sec: Con4mSectionType
    section = secName
    nohdr   = false

  if section == "":
    sec = state.spec.get().rootSpec
  else:
    let secspecs = state.spec.get().secSpecs

    if section notin secspecs:
      return nil

    sec = secspecs[section]

    if sec.hidden and not showHiddenSections:
      return nil

  if sec.shortdoc.isSome():
    result = atom(sec.shortdoc.get())
  else:
    let txt = if section == "":
                atom("command")
              else:
                em(section) + atom(" section")

    result = atom("Configuration for the ") + txt

  if sec.doc.isSome():
    if expandDocField:
      result += markdown(sec.doc.get())
    else:
      result += text(sec.doc.get(), pre = false)
  else:
    result += text("There is no documentation for the section: ") +
          em(section) + text("""
Document this section by adding a 'doc' field to its definition
in your configuration file.
""")

  let fieldsToShow = sec.extractSectionFields(showHidden = showHiddenFields)
  if len(fieldsToShow) == 0:
    result = h1(result)
    return

  var
    cells: seq[seq[Rope]]
    row:   seq[Rope]

  if len(colNames) != 0:
    for item in colNames:
      row.add(th(item))
    cells.add(row)
  else:
    nohdr = true

  for n, f in fieldsToShow:
    row = @[]

    for item in cols:
      case item
      of CcVarName:
        row.add(text(n))
      of CcCurValue:
        row.add(text("not implemented here"))
      of CcShort:
        row.add(atom(f.shortDoc.get("No description available.")))
      of CcLong:
        row.add(markdown(f.doc.get("No documentation for this option.")))
      of CcType:
        case f.extType.kind:
          of TypeC4TypePtr:
            row.add(atom("Type set by field ") + em(f.extType.fieldRef))
          of TypeC4TypeSpec:
            row.add(atom("A type specification"))
          of TypePrimitive:
            row.add(atom($(f.extType.tInfo)))
          else:
            discard
      of CcDefault:
        if f.default.isSome():
          row.add(em(f.extType.tInfo.oneArgToString(f.default.get(),
                                                    lit = true)))
        else:
          row.add(em("None"))
          # TODO: constraints.
    cells.add(row)

  result = quickTable(cells, title = result, noheaders = nohdr, class ="help")

proc buildEntryList(state: ConfigState, categories: openarray[string],
                    skipcategories: bool, groupByCategory: bool):
                   OrderedTable[string, seq[FuncTableEntry]] =

  for _, entryList in state.funcTable:
    for entry in entryList:
      if entry.kind == FnUserDefined:
        continue
      if len(categories) != 0:
        var match = false
        for category in categories:
          if category in entry.tags:
            match = true
            break
        if match and skipcategories:
            continue
        elif not match and not skipcategories:
            continue
      if groupByCategory:
        var primary: string
        for tag in entry.tags:
          if skipcategories and tag in categories:
            continue
          elif not skipcategories and tag notin categories:
            continue
          primary = tag
          break
        if primary notin result:
          result[primary] = @[entry]
        else:
          result[primary].add(entry)
      else:
        if result.len() == 0:
          result[""] = @[entry]
        else:
          result[""].add(entry)

const defaultTitle = "Builtin Functions for Configuration Files"

proc getBuiltinsTableDoc*(state: ConfigState,
                          categories: openarray[string] = ["introspection"],
                          skipcategories = true,
                          columns        = [BiSig, BiLong],
                          byCategory     = true,
                          expandDoc      = true,
                          colnames       = ["Signature", "Description"],
                          title          = atom(defaultTitle)): Rope =
  ## If skipcategories is true, we skip funcs with category names
  ## matching an item in the list. However, when it is false,
  ## we ONLY include funcs with matching categories.
  var
    cells: seq[seq[Rope]]
    row:   seq[Rope]
    nohdrs = if len(colnames) == 0: true else: false

  if not byCategory:
    if len(colnames) != 0:
      for item in colnames:
        row.add(th(item))
      cells.add(row)

  elif title != nil:
    result = h2(title)

  for category, funcs in state.buildEntryList(categories, skipCategories,
                                              byCategory):
    if byCategory:
      cells = @[]
      row   = @[]
      if len(colnames) != 0:
        for item in colnames:
          row.add(th(item))
        cells.add(row)

    for entry in funcs:
      row = @[]

      for col in columns:
        case col
        of BiSig:
          row.add(em(entry.name & $(entry.tInfo)))
        of BiCategories:
          row.add(atom(entry.tags.join(", ")))
        of BiLong:
          row.add(markdown(entry.doc.getOrElse("No description available.")))

      cells.add(row)

    if byCategory:
      var title = atom("Builtins in category: ") + em(category)
      result += quickTable(cells, title = title, noheaders = nohdrs,
                                          class = "help")

  if not byCategory:
    result = quickTable(cells, title = title, noheaders = nohdrs,
                                       class = "help")

proc getOneInstanceForDocs*(state: ConfigState, obj: AttrScope):
                          ObjectFieldDocs =
  ## Whereas getAllFieldInfoForObj returns everything, this function
  ## doesn't give the spec docs, just values and props for specific fields you
  ## request.
  for name, scope in obj.contents:
    if isA(obj.contents[name], AttrScope):
      continue
    var info = FieldPropDocs()
    obj.fillFromObj(name, info)
    result[name] = info

var sectionDocCache = Table[string, SectionObjDocs]()

proc getAllInstanceRawDocs*(state: ConfigState, fqn: string): SectionObjDocs =
  if fqn in sectionDocCache:
    return sectionDocCache[fqn]

  let obj = state.attrs.getObject(fqn)

  for name, scopeOrAttr in obj.contents:
    if scopeOrAttr.isA(Attribute):
      continue
    let scope = scopeOrAttr.get(AttrScope)
    result[name] = state.getOneInstanceForDocs(scope)

  sectionDocCache[fqn] = result

proc getObjectValuesAsArray*(state: ConfigState, fqn: string,
                             fieldsToUse: openarray[string],
                             asLit = true,
                             transformers: TransformTableRef = nil):
                               seq[string] =
  let objOpt = state.attrs.getObjectOpt(fqn)

  if objOpt.isNone():
    raise newException(ValueError, "No object found: " & fqn)

  let obj = objOpt.get()
  for name in fieldsToUse:
    if name notin obj.contents:
      result.add("*None*")
      continue
    if obj.contents[name].isA(AttrScope):
      result.add("*Not a field*")
      continue
    let
      valueType   = obj.contents[name].get(Attribute).tInfo
      valueAsBox  = get[Box](obj, name)
      valAsString = valueType.oneArgToString(valueAsBox, lit = asLit)

    if transformers == nil or name notin transformers:
      result.add(valAsString)

    else:
      result.add(transformers[name](name, valAsString))

proc getValuesForAllObjects*(state: ConfigState, fqn: string,
                             fieldsToUse: openarray[string],
                             asLit = true, filter: openarray[string] = [],
                             colsToMatch: openarray[string] = [],
                             transformers: TransformTableRef = nil):
                               seq[seq[Rope]] =
  let objOpt = state.attrs.getObjectOpt(fqn)
  var
    combinedCols: seq[string]
    searchIx:     seq[int]
    doFilter = false

  for item in fieldsToUse:
    combinedCols.add(item)

  if len(filter) != 0:
    doFilter = true

    for i, item in colsToMatch:
      if item notin fieldsToUse:
        searchIx.add(combinedCols.len())
        combinedCols.add(item)
      else:
        searchIx.add(i)


  if objOpt.isNone():
    raise newException(ValueError, "No object found: " & fqn)

  let obj = objOpt.get()
  for k, v in obj.contents:

    if v.isA(Attribute):
      continue
    var thisRow = @[atom(k)]

    let rest = state.getObjectValuesAsArray(fqn & "." & k, combinedCols, asLit,
                                                        transformers)
    if doFilter:
      var addedRow = false

      for ix in searchIx:
        if ix < rest.len():
          for item in filter:
            if item in rest[ix]:
              for n in rest:
                thisRow.add(text(n))
              # .. instead of ..< b/c we also added name to front
              result.add(thisRow[0 .. fieldsToUse.len()])
              addedRow = true
              break
        if addedRow:
          break

    else:
      for item in rest:
        thisRow.add(text(item))
      result.add(thisRow)

proc getAllInstanceDocsAsArray*(state: ConfigState, fqn: string,
                                fieldsToUse: openarray[string],
                                transformers: TransformTableRef = nil):
                                  seq[seq[string]] =
  let allInfo = state.getAllInstanceRawDocs(fqn)

  for name, fieldDocs in allInfo:
    var curResult: seq[string]

    curResult.add(name)

    for i, field in fieldsToUse:
      let propDocs = if field in fieldDocs:
                       fieldDocs[field]
                     else: nil

      var oneValue = if propDocs == nil:
                       "*None*"
                     else:
                       propDocs["value"]

      if transformers != nil and field in transformers:
        oneValue = transformers[field](field, oneValue)

      curResult.add(oneValue)

    result.add(curResult)


proc cellsToItems(cells: seq[seq[Rope]]): Rope =
  var listItems: seq[Rope]

  for row in cells:
    var cur = Rope(nil)

    for item in row:
      if cur == nil:
        cur = item
      else:
        cur = cur.link(item)
    if cur != nil:
      listItems.add(cur)

  return ul(listItems)

proc getInstanceDocs*(state:          ConfigState,
                      fqn:            string,
                      fieldsToUse:    openarray[string],
                      headings:       openarray[string]  = [],
                      searchFields:   openarray[string]  = [],
                      searchTerms:    openarray[string]  = [],
                      title                              = Rope(nil),
                      caption                            = Rope(nil),
                      transformers:   TransformTableRef  = nil): Rope =
  var
    gotAnyMatch = false
    cells: seq[seq[Rope]]
    row:   seq[Rope]
    found: bool

  if headings.len() != 0:
    row = @[]

    for item in headings:
      row.add(th(item))
    cells.add(row)

  let allInfo = state.getAllInstanceRawDocs(fqn)

  for name, fieldDocs in allInfo:

    if searchTerms.len() != 0:
      found = false
      for term in searchTerms:
        if term.toLowerAscii() in name.toLowerAscii():
          found       = true
          gotAnyMatch = true
      for field in searchFields:
        if found: break
        if field notin fieldDocs:
          continue
        for term in searchTerms:
          if term.toLowerAscii() in fieldDocs[field]["value"].toLowerAscii():
            found       = true
            gotAnyMatch = true
            break
    else:
      found       = true
      gotAnyMatch = true

    if not found:
      continue

    row = @[atom(name)]
    for i, field in fieldsToUse:
      if field in fieldDocs:
        let propDocs = fieldDocs[field]
        if transformers != nil and field in transformers:
          row.add(atom(transformers[field](field, propDocs["value"])))
        else:
          row.add(markdown(propDocs["value"]))
      else:
        row.add(em("None"))
    cells.add(row)

  var noHeaders = if headings.len() == 0: true else: false

  result = quickTable(cells, noHeaders = noHeaders, title = title,
                                         caption = caption, class = "help")
