## Reading from a con4m file, generate a ConfigSpec object to use for
## checking some *other* con4m file.  (⊙ꇴ⊙)
##
## The most mind-bending thing I've done in a while was in building a
## test case for this, where I wrote a partial implementation of the
## c42 spec. It hurts my brain even thinking about it.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023

import tables, strformat, options, streams, nimutils
import types, parse, spec, errmsg, typecheck, dollars, st, legacy

const
  validatorSig    = "func(string, `t) -> string"
  objValidatorSig = "func(string) -> string"

proc buildC42Spec*(): ConfigSpec =
  # We're going to read a con4m file in from users with their specification
  # for what is allowed when parsing THEIR config files.  We're going to
  # read that in and compare *their* structure to what *we* expect, so
  # this is the spec object validating THEIR spec.
  result = newSpec()
  let
    rootScope  = result.getRootSpec()
    rootSec    = result.sectionType("root", singleton = true)
    field      = result.sectionType("field")
    singleton  = result.sectionType("singleton")
    obj        = result.sectionType("object")
    require    = result.sectionType("require")
    allow      = result.sectionType("allow")
    exclusions = result.sectionType("exclusions", singleton = true)

  rootSec.addSection("field")
  rootSec.addSection("require")
  rootSec.addSection("allow")
  rootSec.addSection("exclusions")
  rootSec.addAttr("user_def_ok",     boolType,   true)
  rootSec.addAttr("gen_typename",    stringType, false)
  rootSec.addAttr("gen_field_decls", boolType,   false)
  rootSec.addAttr("gen_loader",      boolType,   false)
  rootSec.addAttr("gen_setters",     boolType,   false)
  rootSec.addAttr("gen_getters",     boolType,   false)
  rootSec.addAttr("extra_decls",     stringType, false)
  rootSec.addAttr("prologue",        stringType, false)
  rootsec.addAttr("doc",             stringType, false)
  rootsec.addAttr("shortdoc",        stringType, false)
  rootSec.addAttr("validator",       toCon4mType(objValidatorSig), false)

  singleton.addSection("field")
  singleton.addSection("require")
  singleton.addSection("allow")
  singleton.addSection("exclusions")
  singleton.addAttr("user_def_ok",     boolType,   true)
  singleton.addAttr("gen_typename",    stringType, false)
  singleton.addAttr("gen_fieldname",   stringType, false)
  singleton.addAttr("gen_field_decls", boolType,   false)
  singleton.addAttr("gen_loader",      boolType,   false)
  singleton.addAttr("gen_setters",     boolType,   false)
  singleton.addAttr("gen_getters",     boolType,   false)
  singleton.addAttr("extra_decls",     stringType, false)
  singleton.addAttr("doc",             stringType, false)
  singleton.addAttr("shortdoc",        stringType, false)
  singleton.addAttr("validator",       toCon4mType(objValidatorSig), false)

  obj.addSection("field")
  obj.addSection("require")
  obj.addSection("allow")
  obj.addSection("exclusions")
  obj.addAttr("user_def_ok",     boolType,   true)
  obj.addAttr("gen_typename",    stringType, false)
  obj.addAttr("gen_fieldname",   stringType, false)
  obj.addAttr("gen_field_decls", boolType,   false)
  obj.addAttr("gen_loader",      boolType,   false)
  obj.addAttr("gen_setters",     boolType,   false)
  obj.addAttr("gen_getters",     boolType,   false)
  obj.addAttr("extra_decls",     stringType, false)
  obj.addAttr("doc",             stringType, false)
  obj.addAttr("shortdoc",        stringType, false)
  obj.addAttr("hidden",          boolType,   false)
  obj.addAttr("validator",       toCon4mType(objValidatorSig), false)

  rootScope.addSection("root", min = 1, max = 1)
  rootScope.addSection("singleton")
  rootScope.addSection("object")

  field.addAttr("type",           toCon4mType("typespec or string"), true)
  field.addAttr("default",        newTypeVar(), true)
  field.addAttr("require",        boolType,     true)
  field.addAttr("write_lock",     boolType,     false)
  field.addAttr("range",          toCon4mType("tuple[int, int]"), false)
  field.addAttr("choice",         toCon4mType("list[`T]"),   false)
  field.addAttr("validator",      toCon4mType(validatorSig), false)
  field.addAttr("stack_limit",    intType,      false)
  field.addAttr("min_items",      intType,      false)
  field.addAttr("max_items",      intType,      false)
  field.addAttr("gen_field_decl", boolType,     false)
  field.addAttr("gen_loader",     boolType,     false)
  field.addAttr("gen_setter",     boolType,     false)
  field.addAttr("gen_getter",     boolType,     false)
  field.addAttr("gen_fieldname",  stringType,   false)
  field.addAttr("doc",            stringType,   false)
  field.addAttr("shortdoc",       stringType,   false)
  field.addAttr("hidden",         boolType,     false)
  field.addExclusion("default", "require")
  require.addAttr("write_lock",   boolType,   false)
  allow.addAttr("write_lock",     boolType,   false)
  exclusions.addAttr("*",         stringType, false)

# TODO: make sure everything used as a section type is a valid ID
proc populateSec(spec:    ConfigSpec,
                 tinfo:   Con4mSectionType,
                 scope:   AttrScope,
                 require: bool) =
  let minSz = if require: 1 else: 0

  for k, v in scope.contents:
    if k notin spec.secSpecs:
      specErr(scope, fmt"No section type named '{k}' defined in spec")
    let
      fields = v.get(AttrScope).contents
      lock   = if "write_lock" in fields:
                 unpack[bool](fields["write_lock"].get(Attribute).value.get())
               else:
                 false
    tinfo.addSection(k, min = minSz, lock = lock)

template getField(fields: OrderedTable[string, AttrOrSub], name: string): untyped =
  if name notin fields:
    specErr(scope, "Expected a field '" & name & "'")
  let aOrS = fields[name]

  if not aOrS.kind:
    specErr(scope, "Expected '{name}' to be a field, but it is a section")

  var res = aOrS.attr
  res

proc unpackValue[T](scope: AttrScope, attr: Attribute, typeStr: string): T =
  let
    c4Type = toCon4mType(typeStr)
    valOpt = attr.value

  if attr.getType().unify(c4Type).isBottom():
    specErr(attr, "Field '" & attr.name & "' should be " & typeStr &
                   ", but got: " & $(attr.getType()))
  if valOpt.isNone():
    specErr(attr,
            "Expected '" & attr.name & "' to have a value; none was provided")
  let box = valOpt.get()

  try:
    when T is (int, int):
      var box = unpack[seq[Box]](box)
      result = (unpack[int](box[0]), unpack[int](box[1]))
    else:
      result = unpack[T](box)
  except:
    specErr(attr,
            "Wrong type for '" & attr.name & "', expected a '" & typeStr &
              "', but got a '" & $(attr.getType()) & "'")

template getValOfType(fields:  OrderedTable[string, AttrOrSub],
                      name:    string,
                      typeStr: string,
                      nimType: typedesc): untyped =
  unpackValue[nimType](scope, getField(fields, name), typeStr)

template valIfPresent(fields:  OrderedTable[string, AttrOrSub],
                      name:    string,
                      c4mType: string,
                      nimType: typedesc,
                      default: untyped): untyped =
  if name in fields: getValOfType(fields, name, c4mType, nimType)
  else:              default

template optValIfPresent(fields:  OrderedTable[string, AttrOrSub],
                         name:    string,
                         c4mType: string,
                         nimType: typedesc): untyped =
  if name in fields:  some(getValOfType(fields, name, c4mType, nimType))
  else:               none(nimType)

proc populateFields(spec:       ConfigSpec,
                    tInfo:      Con4mSectionType,
                    scope:      AttrScope,
                    exclusions: seq[(string, string)]) =
  for k, v in scope.contents:
    var
      default:    Option[Box] = none(Box)
    let
      # valIfPresent sets defaults that we use even if not passed. The
      # fields using optValIfPresent don't get used if not provided.
      # choiceOpt is a snowflake b/c we have to make a type decision before
      # we pull the value out.
      fields     = v.get(AttrScope).contents
      typeField  = getField(fields, "type")
      typeTSpec  = typeField.getType()
      lock       = valIfPresent(fields, "write_lock", "bool", bool, false)
      validator  = valIfPresent(fields, "validator", validatorSig,
                                CallbackObj, nil)
      stackLimit = valIfPresent(fields, "stack_limit", "int", int, -1)
      require    = valIfPresent(fields, "require", "bool", bool, false)
      `range?`   = optValIfPresent(fields, "range", "tuple[int, int]",
                                   (int, int))
      `min?`     = optValIfPresent(fields, "min_items", "int", int)
      `max?`     = optValIfPresent(fields, "max_items", "int", int)
      choiceOpt  = if "choice" in fields: some(getField(fields, "choice"))
                   else:                  none(Attribute)
      `doc?`     = optValIfPresent(fields, "doc", "string", string)
      `sdoc?`    = optValIfPresent(fields, "shortdoc", "string", string)
      hidden     = valIfPresent(fields, "hidden", "bool", bool, false)

    if "default" in fields:
      if "require" in fields:
        specErr(scope, "Cannot have 'require' and 'default' together")
      let
        attr         = getField(fields, "default")
        attrTypeStr  = $(attr.getType())

      if not typeTSpec.unify(stringType).isBottom():
        specErr(scope, "Fields that get their type from other fields may " &
                       "not have a default value")
      else:
        let usersType = unpack[Con4mType](typeField.value.get())
        if usersType.unify(attr.getType()).isBottom():
          specErr(scope, fmt"for {k}: default value actual type " &
                         fmt"({attrTypeStr}) does not match the provided " &
                         fmt"'type' field, which had type: {`$`(usersType)}")

      default = attr.value # We leave it as a boxed option.
    elif "require" notin fields:
      specErr(v.get(AttrScope),
              "Fields must specify one of 'require' or 'default'")

    var count = 0
    if choiceOpt.isSome():                 count = count + 1
    if `range?`.isSome():                  count = count + 1
    if `min?`.isSome() or `max?`.isSome(): count = count + 1

    if count > 1:
      specErr(v.get(AttrScope),
              "Can't specify multiple constraint types on one field.")
    if count != 0 and not typeTSpec.unify(stringType).isBottom():
      specErr(v.get(AttrScope),
              "Fields typed from another field can't have constraints")

    if not typeTSpec.unify(stringType).isBottom():
      let refField = unpack[string](typeField.value.get())
      tInfo.addC4TypePtr(k, refField, require, lock, stackLimit, validator,
                         `doc?`, `sdoc?`, hidden)
    else:
      let usrType = unpack[Con4mType](typeField.value.get())

      if choiceOpt.isSome():
        case usrType.kind
        of TypeString:
          let v = unpackValue[seq[string]](scope, choiceOpt.get(),
                                           "list[string]")
          addChoiceField(tinfo, k, v, require, lock, stackLimit, default,
                         validator, `doc?`, `sdoc?`, hidden)
        of TypeInt:
          let v = unpackValue[seq[int]](scope, choiceOpt.get(), "list[int]")
          addChoiceField(tinfo, k, v, require, lock, stackLimit, default,
                         validator, `doc?`, `sdoc?`, hidden)
        else:
          specErr(v.get(AttrScope),
                  "Choice field must have type 'int' or 'string'")
      elif `range?`.isSome():
        let (l, h) = `range?`.get()
        tInfo.addRangeField(k, l, h, require, lock, stackLimit, default,
                            validator, `doc?`, `sdoc?`, hidden)
      elif `min?`.isSome() or `max?`.isSome():
        var
          min_val = `min?`.getOrElse(-1)
          max_val = `max?`.getOrElse(-1)
        tInfo.addBoundedContainer(k, min_val, max_val, usrType, require, lock,
                      stackLimit, default, validator, `doc?`, `sdoc?`, hidden)
      elif usrType.kind == TypeTypeSpec:
        tInfo.addC4TypeField(k, require, lock, stackLimit, default, validator,
                             `doc?`, `sdoc?`, hidden)
      else:
        tInfo.addAttr(k, usrType, require, lock, stackLimit, default,
                      validator, `doc?`, `sdoc?`, hidden)

  # Once we've processed all fields, check exclusion constraints.
  for (k, v) in exclusions:
    if k notin tInfo.fields:
      specErr(scope, fmt"Cannot exclude undefined field {k}")
    if v notin tInfo.fields:
      specErr(scope, fmt"Cannot exclude undefined field {v}")
    let
      kAttr = tInfo.fields[k]
      vAttr = tInfo.fields[v]
    if k notin vAttr.exclusions:
      vAttr.exclusions.add(k)
    if v notin kAttr.exclusions:
      kAttr.exclusions.add(v)

proc getExclusions(s: AttrScope): seq[(string, string)] =
  result = @[]

  for k, aOrS in s.contents:
    result.add((k, unpack[string](aOrS.get(Attribute).value.get())))

proc populateType(spec: ConfigSpec, tInfo: Con4mSectionType, scope: AttrScope) =
  let pairs = if "exclusions" in scope.contents:
                getExclusions(scope.contents["exclusions"].get(AttrScope))
              else: seq[(string, string)](@[])
  if "field" in scope.contents:
    spec.populateFields(tInfo, scope.contents["field"].get(AttrScope), pairs)
  elif len(pairs) != 0:
    specErr(scope, "Can't have exclusions without fields!")
  if "require" in scope.contents:
    spec.populateSec(tinfo, scope.contents["require"].get(AttrScope), true)
  if "allow" in scope.contents:
    spec.populateSec(tinfo, scope.contents["allow"].get(AttrScope), false)
  let attr = scope.contents["user_def_ok"].get(Attribute)

  if unpack[bool](attr.value.get()):
    addAttr(tInfo, "*", newTypeVar(), false)

  tInfo.doc      = getOpt[string](scope, "doc")
  tInfo.shortdoc = getOpt[string](scope, "shortdoc")

template setDocInfo() {.dirty.} =
  var
    shortdoc  = none(string)
    doc       = none(string)
    hidden    = false
    validator = CallbackObj(nil)


  if "doc" in objInfo.contents:
    let boxopt = objInfo.contents["doc"].get(Attribute).value
    if boxopt.isSome():
      doc = some(unpack[string](boxopt.get()))
  if "shortdoc" in objInfo.contents:
    let boxopt = objInfo.contents["shortdoc"].get(Attribute).value
    if boxopt.isSome():
      shortdoc = some(unpack[string](boxopt.get()))
  if "hidden" in objInfo.contents:
    let boxopt = objInfo.contents["hidden"].get(Attribute).value
    if boxOpt.isSome():
      hidden = unpack[bool](boxopt.get())
  if "validator" in objInfo.contents:
    let boxopt = objInfo.contents["validator"].get(Attribute).value
    if boxOpt.isSome():
      validator = unpack[CallbackObj](boxopt.get())

proc registerSingletonType(spec: ConfigSpec, item: AttrOrSub) =
  let objInfo  = item.get(AttrScope)
  setDocInfo()
  spec.sectionType(objInfo.name, singleton = true, doc = doc,
                   shortdoc = shortdoc, hidden = hidden,
                   validator = validator)

proc registerObjectType(spec: ConfigSpec, item: AttrOrSub) =
  let objInfo  = item.get(AttrScope)
  setDocInfo()
  spec.sectionType(objInfo.name, singleton = false, doc = doc,
                   shortdoc = shortdoc, hidden = hidden,
                   validator = validator)

proc generateC42Spec*(state: ConfigState,
                      oldSpec: Option[ConfigSpec] = none(ConfigSpec)):
                        ConfigSpec =
  result       = newSpec()
  let contents = state.attrs.contents

  # Register all types before we populate them, so that we can safely
  # forward-reference; all type names will be registered before we
  # populate.

  if "singleton" in contents:
    for _, singletonSpec in contents["singleton"].get(AttrScope).contents:
      result.registerSingletonType(singletonSpec)

  if "object" in contents:
    for _, objectSpec in contents["object"].get(AttrScope).contents:
      result.registerObjectType(objectSpec)

  if oldSpec.isSome():
    let actually = oldSpec.get()

    for k, v in actually.secSpecs:
      if k notin result.secSpecs:
        result.secSpecs[k] = v

  if "singleton" in contents:
    for name, singletonSpec in contents["singleton"].get(AttrScope).contents:
      result.populateType(result.secSpecs[name], singletonSpec.get(AttrScope))

  if "object" in contents:
    for name, objectSpec in contents["object"].get(AttrScope).contents:
      result.populateType(result.secSpecs[name], objectSpec.get(AttrScope))

  result.populateType(result.rootSpec, contents["root"].get(AttrScope))

proc c42Spec*(s:        Stream,
              fileName: string): Option[(ConfigSpec, ConfigState)] =
  ## Create a ConfigSpec object from a con4m file. The schema is
  ## validated against our c42-spec format.
  let (cfgContents, success) = firstRun(s, fileName, buildC42Spec())

  if not success:
    return none((ConfigSpec, ConfigState))

  return some((cfgContents.generateC42Spec(), cfgContents))


proc c42Spec*(c: string, fname: string): Option[(ConfigSpec, ConfigState)] =
  return c42Spec(newStringStream(c), fname)

proc c42Spec*(filename: string): Option[(ConfigSpec, ConfigState)] =
  var s = newFileStream(filename)

  if s == nil:
    fatal(fmt"Unable to open specification file '{filename}' for reading")

  return c42Spec(s.readAll().newStringStream(), filename)
