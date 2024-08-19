import strutils, strformat, tables, nimutils, unicode, options
import types, st

type VarDeclInfo = ref object
  name:         string       # The variable name someone asked for,
                             # taken from gen_fieldname, if provided. This is
                             # a base name for the target language we combine
                             # when creating getters and setters.
  unquoted:     string       # A version of name that's quoted in the target
                             # lang, if quoting is needed.  Same as prev field
                             # if not. This is used for the declared variable.
  c4Name:       string       # This is the name when it's used in a con4m file,
                             # for when we ask for it with attrLookup.
  c4mType:      Con4mType
  alwaysExists: bool
  localType:    string
  genFieldDecl: Option[bool]
  genLoader:    Option[bool]
  genGetter:    Option[bool]
  genSetter:    Option[bool]

type SecTypeInfo = ref object
  singleton:     bool
  name:          string    # c4name
  nameOfType:    string
  nameWhenField: string
  genFieldDecls: bool
  genLoader:     bool
  genSetters:    bool
  genGetters:    bool
  extraDecls:    string
  scope:         AttrScope
  backRefs:      seq[string] # List of types we use.
  backRefCount:  int         # Used to know when a type can be added.
  requiredBy:    seq[string] # types that use us.
  fieldInfo:     OrderedTable[string, VarDeclInfo]

const reservedWords = {
  "nim": ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
          "concept", "const", "continue", "converter", "defer", "discard",
          "distinct", "div", "do", "elif", "else", "end", "enum", "except",
          "export", "finally", "for", "from", "func", "if", "import", "in",
          "include", "interface", "is", "isnot", "iterator", "let", "macro",
          "method", "mixin", "mod", "nil", "not", "notin", "object", "of",
          "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr",
          "static", "template", "try", "tuple", "type", "using", "var", "when",
          "while", "xor", "yield"]
}.toTable()

proc quote(id: string, lang: string): string =
  if lang notin reservedWords:
    raise newException(ValueError, "Unsupported language: '" & lang & "'")
  let rw = reservedWords[lang]
  if rw.contains(id):
    case lang
    of "nim":
      return "`" & id & "`"
    else:
      unreachable
  else:
    return id

template depGraphOneSection(subs:    AttrScope,
                            key:     string,
                            oneSec:  SecTypeInfo) =
  if "require" in subs.contents:
    var required = subs.contents["require"].get(AttrScope)
    for k, v in required.contents:
      if k == key:
        continue
      var targetsec: SecTypeInfo
      if k in secInfo:
        targetsec = secInfo[k]
      else:
        targetSec = SecTypeInfo(name: k, scope: nil)
        secInfo[k] = targetsec
      onesec.backRefs.add(k)
      targetSec.requiredBy.add(key)
  if "allow" in subs.contents:
    var allowed = subs.contents["allow"].get(AttrScope)
    for k, v in allowed.contents:
      if k == key:
        continue
      var targetsec: SecTypeInfo
      if k in secInfo:
        targetsec = secInfo[k]
      else:
        targetSec = SecTypeInfo(name: k, scope: nil)
        secInfo[k] = targetsec
      oneSec.backRefs.add(k)
      targetSec.requiredBy.add(key)

template depGraphProcessOneObjectClass(kind: string, singVal: bool) =
  let aOrE = attrLookup(c42state.attrs, [kind], 0, vlSecUse)
  if aOrE.isA(AttrOrSub):
    let objTypeList = aOrE.get(AttrOrSub).get(AttrScope)
    var onesec: SecTypeInfo
    for key, aOrS in objTypeList.contents:
      if key notin secInfo:
        oneSec = SecTypeInfo(name: key, scope: nil, singleton: singVal)
        secInfo[key] = oneSec
      else:
        oneSec = secInfo[key]
      let subs = aOrS.get(AttrScope)
      if oneSec.scope == nil:
        oneSec.scope     = subs
        oneSec.singleton = singVal
      depGraphOneSection(subs, key, oneSec)

# We want to generate type declarations in a sane order, ensuring that
# No type is forward referenced.
proc orderTypes(c42state: ConfigState,
                secInfo:  var Table[string, SecTypeInfo]): seq[SecTypeInfo] =
  result = @[]

  depGraphProcessOneObjectClass("object", false)
  depGraphProcessOneObjectClass("singleton", true)
  while len(secInfo) != 0:
    block outer:
      for k, v in secInfo:
        if len(v.backRefs) == v.backRefCount:
          result.add(v)
          for link in v.requiredBy:
            var linkedSect = secInfo[link]
            linkedSect.backRefCount = linkedSect.backRefCount + 1
          secInfo.del(k)
          break outer
      raise newException(ValueError, "Cannot produce code for types with " &
                                     "circular dependencies")

proc declToNimType(v: Con4mType): string =
  case v.kind
  of TypeBool:
    return "bool"
  of TypeString:
    return "string"
  of TypeDuration:
    return "Con4mDuration"
  of TypeIPAddr:
    return "Con4mIPAddr"
  of TypeCIDR:
    return "Con4mCIDR"
  of TypeSize:
    return "Con4mSize"
  of TypeDate:
    return "Con4mDate"
  of TypeTime:
    return "Con4mTime"
  of TypeDateTime:
    return "Con4mDateTime"
  of TypeTypeSpec:
    return "Con4mType"
  of TypeFunc:
    return "CallbackObj"
  of TypeInt:
    return "int"
  of TypeChar:
    return "char"
  of TypeFloat:
    return "float"
  of TypeTuple, TypeTVar:
    return "Box"
  of TypeList:
    return "seq[" & v.itemType.declToNimType() & "]"
  of TypeDict:
    return "TableRef[" &
      v.keyType.declToNimType() & ", " &
      v.valType.declToNimType() & "]"
  of TypeBottom:
    unreachable

proc genOneSectNim(me:       SecTypeInfo,
                   allSects: TableRef[string, SecTypeInfo]): string =
  result = "type " & me.nameOfType & "* = ref object\n"
  # @@attrscope@@ needs to always be there, even if we're not generating any
  # fields.  We use it to proxy to con4m, whether or not we are locally caching.
  result &= "  `@@attrscope@@`*: AttrScope\n"
  # Individual sections can't override whether they get declared the way fields can.
  for item in me.backRefs:
    let o = allSects[item]
    if o.singleton:
      result &= "  {o.nameWhenField}*: {o.nameOfType}\n".fmt()
    else:
      result &= "  {o.nameWhenField}*:".fmt()
      result &= " OrderedTableRef[string, {o.nameOfType}]\n".fmt()
  for name, info in me.fieldInfo:
    info.localType = info.c4mType.declToNimType()

    if info.genFieldDecl.isSome():
      if not info.genFieldDecl.get():
        continue
    elif not me.genFieldDecls:
      continue
    if info.alwaysExists:
      result &= "  {name}*: {info.localType}\n".fmt()
    else:
      result &= "  {name}*: Option[{info.localType}]\n".fmt()
  if me.extraDecls != "":
    let lines = strutils.split(me.extraDecls, "\n")
    for line in lines:
      let l = strutils.strip(line)
      if l != "":
        result &= "  " & l & "\n"
  result &= "\n"

template loaderPrefixNim(): string =
   """
proc load{me.nameOfType}*(scope: AttrScope): {me.nameOfType} =
  result = new({me.nameOfType})
  result.`@@attrscope@@` = scope
""".fmt()

template loadSingletonNim(): string =
  """
  if scope.contents.contains("{sec.name}"):
    result.{sec.nameWhenField} = load{sec.nameOfType}(
               scope.contents["{sec.name}"].get(AttrScope))
""".fmt()

template loadObjectNim(): string =
  """
  result.{sec.nameWhenField} = new(OrderedTableRef[string, {sec.nameOfType}])
  if scope.contents.contains("{sec.name}"):
    let objlist = scope.contents["{sec.name}"].get(AttrScope)
    for item, aOrS in objlist.contents:
      result.{sec.nameWhenField}[item] =
               load{sec.nameOfType}(aOrS.get(AttrScope))
""".fmt()

template loadAlwaysFieldNim(): string =
  """
  result.{info.name} = unpack[{info.localType}](scope.attrLookup("{info.c4Name}").get())
""".fmt()

template loadMaybeFieldNim(): string =
  """
  result.{info.name} = none({info.localType})
  if "{info.name}" in scope.contents:
     var tmp = scope.attrLookup("{info.c4Name}")
     if tmp.isSome():
        result.{info.name} = some(unpack[{info.localType}](tmp.get()))
""".fmt()

proc genOneLoaderNim(me:       SecTypeInfo,
                     allSects: TableRef[string, SecTypeInfo]): string =
  result = loaderPrefixNim()
  if me.genFieldDecls:
    for edge in me.backRefs:
      let sec = allSects[edge]
      if not sec.genLoader:
        continue
      if sec.singleton:
        result &= loadSingletonNim()
      else:
        result &= loadObjectNim()
  for field, info in me.fieldInfo:
    if info.genFieldDecl.isSome():
      if not info.genFieldDecl.get():
        continue
    elif not me.genFieldDecls:
      continue
    if info.alwaysExists:
      result &= loadAlwaysFieldNim()
    else:
      result &= loadMaybeFieldNim()
  result &= "\n"

template singletonAndDeclNim(): string =
  """
proc get_{sec.nameWhenField}*(self: {me.nameOfType}): Option[{sec.nameOfType}] =
  if self.{sec.nameWhenField} == nil:
    return none({sec.nameOfType})
  else:
    return some(self.{sec.nameWhenField})

""".fmt()

template objAndDeclNim(): string =
  """
proc get_{sec.nameWhenField}*(self: {me.nameOfType}): OrderedTableRef[string, {sec.nameOfType}] =
  return self.{sec.nameWhenField}

""".fmt()

template singletonWoDeclNim(): string =
  """
proc get_{sec.nameWhenField}*(self: {sec.nameOfType}): Option[{me.nameOfType}] =
  let aOrE = self.`@@attrscope@@`.attrLookup(["{me.name}"], 0, vlSecUse)
  if aOrE.isA(AttrErr):
    return none({sec.nameOfType})
  let aOrS = aOrE.get(AttrOrSub)
  if aOrS.isA(Attribute):
    return none({sec.nameOfType})
  return some(sec.nameOfType(`@@attrscope@@`: aOrS.get(AttrScope)))

""".fmt()

template objWoDeclNim(): string =
  """
proc get_{sec.nameWhenField}*(self: {me.nameOfType}): OrderedTableRef[string, {sec.nameOfType}] =
  let aOrE = self.`@@attrscope@@`.attrLookup(["{me.name}"], 0, vlSecUse)
  if aOrE.isA(AttrErr):
    return nil
  let aOrS = aOrE.get(AttrOrSub)
  if aOrS.isA(Attribute):
    return nil
  let baseScope = aOrS.get(AttrScope)
  result = newOrderedTable[string, {sec.nameOfType}]()
  for k, aOrS2 in baseScope.contents:
    if aOrS2.isA(AttrScope):
      result[k] = {sec.nameOfType}(`@@attrscope@@`: aOrS2.get(AttrScope))

""".fmt()

template fieldGetWDeclDefiniteNim(): string =
  """
proc get_{info.unquoted}*(self: {me.nameOfType}): {info.localType} =
  return self.{info.name}

""".fmt()

template fieldGetWDeclOptNim(): string =
  """
proc get_{info.unquoted}*(self: {me.nameOfType}): Option[{info.localType}] =
  return self.{info.name}

""".fmt()

template fieldGetNoDeclDefiniteNim(): string =
  """
proc get_{info.unquoted}*(self: {me.nameOfType}): {info.localType} =
  let box = self.`@@attrscope@@`.attrLookup("{info.c4Name}").get()
  return unpack[{info.localType}](box)
""".fmt()

template fieldGetNoDeclOptNim(): string =
  """
proc get_{info.unquoted}*(self: {me.nameOfType}): Option[{info.localType}] =
  let boxOpt = self.`@@attrscope@@`.attrLookup("{info.c4Name}")
  if boxOpt.isSome():
    return some(unpack[{info.localType}](boxOpt.get()))
  else:
    return none({info.localType})
""".fmt()

template fieldSetWDeclDefiniteNim(): string =
  """
proc set_{info.unquoted}*(self: {me.nameOfType}, val: {info.localType}): bool {{.discardable.}} =
  let res = self.`@@attrscope@@`.attrSet("{info.c4Name}", pack(val))
  if res.code != errOk:
    return false
  self.{info.name} = unpack[{info.localType}](self.`@@attrscope@@`.attrLookup("{info.c4Name}").get())
  return true

""".fmt()

template fieldSetWDeclOptNim(): string =
  """
proc set_{info.unquoted}*(self: {me.nameOfType}, val: {info.localType}): bool {{.discardable.}} =
  let res = self.`@@attrscope@@`.attrSet("{info.c4Name}", pack(val))
  if res.code != errOk:
    return false
  self.{info.unquoted} = some(unpack[{info.localType}](self.`@@attrscope@@`.attrLookup("{info.c4Name}").get()))
  return true

""".fmt()

template fieldSetNoDeclDefiniteNim(): string =
  """
proc set_{info.unquoted}*(self: {me.nameOfType}, val: {info.localType}): bool {{.discardable.}} =
  let res = self.`@@attrscope@@`.attrSet("{info.c4Name}", pack(val))
  if res.code != errOk:
    return false
  return true

""".fmt()

template fieldSetNoDeclOptNim(): string =
  """
proc set_{info.unquoted}*(self: {me.nameOfType}, val: {info.localType}): bool {{.discardable.}} =
  let res = self.`@@attrscope@@`.attrSet("{info.c4Name}", pack(val))
  if res.code != errOk:
    return false

""".fmt()

proc genGettersNim(me:       SecTypeInfo,
                   allSects: TableRef[string, SecTypeInfo]): string =
  result = """
proc getAttrScope*(self: {me.nameOfType}): AttrScope =
  return self.`@@attrscope@@`

""".fmt()
  if me.genGetters:
    for edge in me.backRefs:
      let  sec = allSects[edge]
      if sec.singleton and me.genFieldDecls:
        result &= singletonAndDeclNim()
      elif sec.singleton:
        result &= singletonWoDeclNim()
      elif me.genFieldDecls:
        result &= objAndDeclNim()
      else:
        result &= objWoDeclNim()

  for name, info in me.fieldInfo:
    if info.genGetter.isSome():
      if not info.genGetter.get(): continue
    elif not me.genGetters: continue

    var genFieldDecls = me.genFieldDecls
    if info.genFieldDecl.isSome():
      genFieldDecls = info.genFieldDecl.get()

    if info.alwaysExists:
      if genFieldDecls:
        result &= fieldGetWDeclDefiniteNim()
      else:
        result &= fieldGetNoDeclDefiniteNim()
    else:
      if genFieldDecls:
        result &= fieldGetWDeclOptNim()
      else:
        result &= fieldGetNoDeclOptNim()

proc genSettersNim(me:       SecTypeInfo,
                   allSects: TableRef[string, SecTypeInfo]): string =
  result = ""
  for field, info in me.fieldInfo:
    if info.genSetter.isSome():
      if not info.genSetter.get(): continue
    elif not me.genSetters: continue

    var genFieldDecls = me.genFieldDecls
    if info.genFieldDecl.isSome():
      genFieldDecls = info.genFieldDecl.get()

    if info.alwaysExists:
      if genFieldDecls:
        result &= fieldSetWDeclDefiniteNim()
      else:
        result &= fieldSetNoDeclDefiniteNim()
    else:
      if genFieldDecls:
        result &= fieldSetWDeclOptNim()
      else:
        result &= fieldSetNoDeclOptNim()

proc genOneSection(me:       SecTypeInfo,
                   allSects: TableRef[string, SecTypeInfo],
                   lang:     string): string =
  case lang
  of "nim":
    return me.genOneSectNim(allSects)
  else:
    unreachable

proc genOneLoader(me:       SecTypeInfo,
                  allSects: TableRef[string, SecTypeInfo],
                  lang:     string): string =
  case lang
  of "nim":
    return me.genOneLoaderNim(allSects)
  else:
    unreachable

proc genGetters(me:       SecTypeInfo,
                allSects: TableRef[string, SecTypeInfo],
                lang:     string): string =
  case lang
  of "nim":
    return me.genGettersNim(allSects)
  else:
    unreachable

proc genSetters(me:       SecTypeInfo,
                allSects: TableRef[string, SecTypeInfo],
                lang:     string): string =
  case lang
  of "nim":
    return me.genSettersNim(allSects)
  else:
    unreachable

proc alwaysExists(name: string, sec: SecTypeInfo, fieldProps: AttrScope): bool =
  let
    required = fieldProps.attrLookup("require")
    default  = fieldProps.attrLookup("default")

  if true:                           return false
  elif default.isSome():             return true
  elif unpack[bool](required.get()): return true
  else:                              return false

proc alwaysExists(s: string, f: AttrScope, x: seq[string]): bool =
  if s in x: return false
  if f.attrLookup("default").isSome(): return true
  if unpack[bool](f.attrLookup("require").get()): return true

  return false

proc buildSectionVarInfo(me: SecTypeInfo, lang: string, xclude: seq[string]) =
  if "field" notin me.scope.contents:
    return
  let fieldscope = me.scope.contents["field"].get(AttrScope)
  for fieldName, fieldAorS in fieldscope.contents:
    let
      fieldProps = fieldAorS.get(AttrScope)
      typeBox    = fieldProps.attrLookup("type").get()
      c4mType    = if typeBox.kind  == MkStr:  newTypeVar()
                   else:                       unpack[Con4mType](typeBox)
      genFieldDeclBox = fieldProps.attrLookup("gen_field_decl")
      genFieldDecl    = if genFieldDeclBox.isSome():
                     some(unpack[bool](genFieldDeclBox.get()))
                   else:
                     none(bool)
      genLoadBox = fieldProps.attrLookup("gen_loader")
      genLoader  = if genLoadBox.isSome():
                     some(unpack[bool](genLoadBox.get()))
                   else:
                     none(bool)
      genGetrBox = fieldProps.attrLookup("gen_getter")
      genGetter  = if genGetrBox.isSome():
                     some(unpack[bool](genGetrBox.get()))
                   else:
                     none(bool)
      genSetrBox = fieldProps.attrLookup("gen_setter")
      genSetter  = if genSetrBox.isSome():
                     some(unpack[bool](genSetrBox.get()))
                   else:
                     none(bool)
      genNameBox = fieldProps.attrLookup("gen_fieldname")
      genName    = if genNameBox.isSome(): unpack[string](genNameBox.get())
                   else:                   fieldName
      always     = fieldName.alwaysExists(fieldProps, xclude)
      qfn        = quote(genName, lang)

    # We don't fill in the localType here, because fields might
    # not be Nim types, and it's easier / more clear to deal w/
    # that logic when needed.
    me.fieldInfo[qfn] = VarDeclInfo(name:         qfn,
                                    unquoted:     genName,
                                    c4Name:       fieldName,
                                    alwaysExists: always,
                                    c4mType:      c4mType,
                                    genFieldDecl: genFieldDecl,
                                    genLoader:    genLoader,
                                    genGetter:    genGetter,
                                    genSetter:    genSetter)

proc prepareForGeneration(tinfo: SecTypeInfo, lang: string) =
  # Load data from con4m into SecTypeInfo field that we're going
  # to want to use in the generation all at once, instead of
  # scrounging for each piece later.
  if "gen_typename" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_typename")
    tinfo.nameOfType = quote(unpack[string](opt.get()), lang)
  else:
    let n            = tinfo.name[0..0].toUpper() & tinfo.name[1..^1] & "Type"
    tinfo.nameOfType = quote(n, lang)

  if "gen_fieldname" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_fieldname")
    tinfo.nameWhenField = quote(unpack[string](opt.get()), lang)
  else:
    tinfo.nameWhenField = quote(tinfo.name & "Objs", lang)

  if "gen_field_decls" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_field_decls")
    tinfo.genFieldDecls = unpack[bool](opt.get())
  else:
    tinfo.genFieldDecls = true

  if "gen_loader" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_loader")
    tinfo.genLoader = unpack[bool](opt.get())
  else:
    tinfo.genLoader = true

  if "gen_setters" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_setters")
    tinfo.genSetters = unpack[bool](opt.get())
  else:
    tinfo.genSetters = true

  if "gen_getters" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("gen_getters")
    tinfo.genGetters = unpack[bool](opt.get())
  else:
    tinfo.genGetters = true

  if "extra_decls" in tinfo.scope.contents:
    let opt = tinfo.scope.attrLookup("extra_decls")
    tinfo.extraDecls = unpack[string](opt.get())

  var inAnExclusion: seq[string] = @[]
  if "exclusions" in tinfo.scope.contents:
    for f, aOrS in tinfo.scope.contents["exclusions"].get(AttrScope).contents:
      let otherField = unpack[string](aOrS.get(Attribute).value.get())
      if f          notin inAnExclusion: inAnExclusion.add(f)
      if otherField notin inAnExclusion: inAnExclusion.add(otherField)


  tinfo.buildSectionVarInfo(lang, inAnExclusion)

proc getPrologue(rootScope: AttrScope, lang: string): string =
  if "prologue" in rootScope.contents:
    let opt = rootScope.attrLookup("prologue")
    result  = unpack[string](opt.get())
  else:
    result  = ""
  case lang
  of "nim":
    result &= "import options, tables, con4m, nimutils/box\n\n"
  else:
    raise newException(ValueError,
                       "Unsupported language for generation: " & lang)

proc generateCode*(c42state: ConfigState, lang: string): string =
  var
    secInfo: Table[string, SecTypeInfo]
    rootScope    = c42state.attrs
    orderedTypes = c42state.orderTypes(secInfo)
    typeHash     = newTable[string, SecTypeInfo]()
  let
    rootDef   = rootScope.contents["root"].get(AttrScope)
    rootInfo  = SecTypeInfo(singleton: true, nameOfType: "Config",
                            scope: rootDef, requiredBy: @[])

  result = getPrologue(rootDef, lang)

  for typeObj in orderedTypes:
    typeObj.prepareForGeneration(lang)
    typeHash[typeObj.name] = typeObj

  depGraphOneSection(rootDef, "root", rootInfo)
  rootInfo.prepareForGeneration(lang)

  orderedTypes.add(rootInfo)

  for typeObj in orderedTypes:
    result &= genOneSection(typeObj, typeHash, lang)
    if typeObj.genLoader:
      result &= genOneLoader(typeObj, typeHash, lang)
    result &= genGetters(typeObj, typeHash, lang)
    result &= genSetters(typeObj, typeHash, lang)
