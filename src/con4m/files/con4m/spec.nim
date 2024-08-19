## Routines for specifying a config file schema, and for checking an
## executed config against that schema.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022

import options, tables, strutils, strformat, nimutils, macros, unicode, sugar
import builtins, types, typecheck, eval, st, dollars

proc specErr*(scope: AttrScope, msg: string) =
  let
    name = $color(scope.fullNameAsStr(), "cyan")
    full = if len(name) == 0: msg else: fmt"When checking {name}: {msg}"
  raise newException(ValueError, full)

proc specErr*(attr: Attribute, msg: string) =
  let
    name = $color(attr.fullNameAsStr(), "cyan")
    full = if len(name) == 0: msg else: fmt"When checking {name}: {msg}"
  raise newException(ValueError, full)

proc specErr*(msg: string) =
  raise newException(ValueError,
                     fmt"In post execution check, at top-level: {msg}")

proc defErr*(scope: AttrScope, msg: string) =
  let name = $color(scope.fullNameAsStr(), "cyan")
  raise newException(ValueError,
                     fmt"When defining section {name}: {msg}")

proc defErr*(scope: Con4mSectionType, msg: string) =
  let name = $color(scope.typeName, "cyan")
  raise newException(ValueError,
                     fmt"When defining section {name}: {msg}")

proc defErr*(msg: string) =
  raise newException(ValueError,
                     fmt"When defining a top-level section: {msg}")

proc sectionType*(spec:       ConfigSpec,
                  name:       string,
                  singleton:  bool = false,
                  doc:        Option[string] = none(string),
                  shortdoc:   Option[string] = none(string),
                  hidden:     bool = false,
                  validator:  CallbackObj = CallbackObj(nil)
                 ): Con4mSectionType {.discardable.} =
  if name in spec.secSpecs:
    defErr(fmt"Duplicate section type name: {name}")
  result = Con4mSectionType(typeName:      name,
                            singleton:     singleton,
                            backref:       spec,
                            doc:           doc,
                            shortdoc:      shortdoc,
                            hidden:        hidden,
                            validator:     validator)
  if name != "":
    spec.secSpecs[name] = result

proc addAttr*(sect:       Con4mSectionType,
              name:       string,
              tinfo:      Con4mType,
              required:   bool,
              lock:       bool = false,
              stackLimit: int = -1,
              default:    Option[Box] = none(Box),
              validator:  CallbackObj = nil,
              doc:        Option[string] = none(string),
              shortdoc:   Option[string] = none(string),
              hidden:     bool = false
             ): Con4mSectionType {.discardable.} =
  if name in sect.fields:
    defErr(sect, fmt"Duplicate field name: {name}")
  if "*" in name:
    if name != "*":
      defErr(sect, "Attribute wilcard must be '*' only")
    elif required == true:
      defErr(sect, "Wildcard attr spec can't be 'required'")

  let
    tobj = ExtendedType(kind:      TypePrimitive,
                        tinfo:     tinfo,
                        validator: validator)
    info = FieldSpec(extType:     tobj,
                     minRequired: if default.isSome() or required : 1 else: 0,
                     maxRequired: 1,
                     stackLimit:  stackLimit,
                     default:     default,
                     lock:        lock,
                     doc:         doc,
                     shortdoc:    shortdoc,
                     hidden:      hidden)

  sect.fields[name] = info
  return sect

proc addC4TypeField*(sect:       Con4mSectionType,
                     name:       string,
                     required:   bool = true,
                     lock:       bool = false,
                     stackLimit: int = -1,
                     default:    Option[Box] = none(Box),
                     validator:  CallbackObj = nil,
                     doc:        Option[string] = none(string),
                     shortdoc:   Option[string] = none(string),
                     hidden:     bool = false):
                       Con4mSectionType {.discardable.} =
  if name in sect.fields:
    defErr(sect, fmt"Duplicate field name: {name}")
  if "*" in name:
    defErr(sect, "User-defined fields can't be 'type' fields")
  let
    tobj = ExtendedType(kind: TypeC4TypeSpec, validator: validator)
    info = FieldSpec(extType:     tobj,
                     minRequired: if required or default.isSome(): 1 else: 0,
                     maxRequired: 1,
                     stackLimit:  stackLimit,
                     default:     default,
                     lock:        lock,
                     doc:         doc,
                     shortdoc:    doc,
                     hidden:      hidden)
  sect.fields[name] = info
  return sect

proc addC4TypePtr*(sect:        Con4mSectionType,
                   name:        string,
                   pointsTo:    string,
                   required:    bool   = true,
                   lock:        bool   = false,
                   stackLimit:  int    = -1,
                   validator:   CallbackObj = nil,
                   doc:         Option[string] = none(string),
                   shortdoc:    Option[string] = none(string),
                   hidden:      bool = false):
                     Con4mSectionType {.discardable.} =
  if name in sect.fields:
    defErr(sect, fmt"Duplicate field name: '{name}'")
  if "*" in name:
    defErr(sect, "User-defined fields can't be 'type' fields")
  let
    tinfo = ExtendedType(kind:      TypeC4TypePtr,
                         fieldRef:  pointsTo,
                         validator: validator)
    info  = FieldSpec(extType:     tinfo,
                      minRequired: if required: 1 else: 0,
                      maxRequired: 1,
                      stackLimit:  stackLimit,
                      default:     none(Box),
                      lock:        lock,
                      doc:         doc,
                      shortdoc:    shortdoc,
                      hidden:      hidden)

  sect.fields[name] = info
  return sect

# For addChoiceField and addRangeField, we don't check to see if
# default is in range; we assume the developer knows what they're
# doing and wants the default to only be appliable if no value is
# given.  Better specing it here rather than hardcoding it internal to
# the app.
proc addChoiceField*[T](sect:       Con4mSectionType,
                        name:       string,
                        choices:    seq[T],
                        required:   bool        = true,
                        lock:       bool        = false,
                        stackLimit: int         = -1,
                        default:    Option[Box] = none(Box),
                        validator:  CallbackObj = nil,
                        doc:        Option[string] = none(string),
                        shortdoc:   Option[string] = none(string),
                        hidden:     bool = false) =
  var attrType: Con4mType

  when T is string:
    attrType = stringType
  elif T is int:
    attrType = intType
  else:
    static:
      error("addChoiceField must take a sequence of ints or strings")

  addAttr(sect, name, attrType, required or default.isSome(),
          lock, stackLimit, default, validator, doc, shortdoc, hidden)
  var tobj = sect.fields[name].extType

  if tobj.range[0] != tobj.range[1]:
    defErr(sect, "Can't set both range and choice on the same field")
  elif len(tobj.intChoices) + len(tobj.strChoices) != 0:
    defErr(sect, "Already have choices established!")
  elif len(choices) <= 1:
    defErr(sect, fmt"When defining field '{name}': must offer 2 or more " &
                    "choices, or else it's not a choice!")

  when T is string:
    tobj.strChoices = choices
  elif T is int:
    tobj.intChoices = choices

proc addRangeField*(sect:       Con4mSectionType,
                    name:       string,
                    rangemin:   int,
                    rangemax:   int,
                    required:   bool        = true,
                    lock:       bool        = false,
                    stackLimit: int         = -1,
                    default:    Option[Box] = none(Box),
                    validator:  CallbackObj = nil,
                    doc:        Option[string] = none(string),
                    shortdoc:   Option[string] = none(string),
                    hidden:     bool = false) =
  addAttr(sect, name, intType, required or default.isSome(), lock,
          stackLimit, default, validator, doc, shortdoc, hidden)
  var tobj = sect.fields[name].extType

  if rangemin >= rangemax:
    defErr(sect, "Invalid range.")
  elif len(tobj.intChoices) + len(tobj.strChoices) != 0:
    defErr(sect, "Can't offer choices and a range.")

  tobj.range = (rangemin, rangemax)

proc addBoundedContainer*(sect:       Con4mSectionType,
                          name:       string,
                          minSize:    int,
                          maxSize:    int,
                          tinfo:      Con4mType,
                          required:   bool,
                          lock:       bool        = false,
                          stackLimit: int         = -1,
                          default:    Option[Box] = none(Box),
                          validator:  CallbackObj = nil,
                          doc:        Option[string] = none(string),
                          shortdoc:   Option[string] = none(string),
                          hidden:     bool = false) =
  case tinfo.getBaseType()
  of TypeDict, TypeList:
    addAttr(sect, name, tinfo, required or default.isSome(), lock,
            stackLimit, default, validator, doc, shortdoc, hidden)
    if minSize < 0 and maxSize < 0:
      defErr(sect, "Constraint must apply to either min or max to use this")
    if minSize >= 0 and maxSize >= 0 and minSize >= maxSize:
      defErr(sect, "Invalid size specification (min >= max)")
    var tobj = sect.fields[name].extType
    tobj.itemCount = (minSize, maxSize)
  of TypeInt:
    defErr(sect, "Bounded containers are for dicts and lists; use range " &
                 "fields for integers.")
  else:
    defErr(sect, "Bounded containers must be dict or list types")

# Use this to add simple mutual exclusions... if we see X, then we're
# not allowed. For instance, in the c42 spec, default: and required:
# are mutually exclusive, but at least one of them is required.
#
# So we mark them as both required and mutually exclusive.
#
# The 'min required' is only enforced when there are no exclusions.
proc addExclusion*(sect: Con4mSectionType, fieldName1, fieldName2: string) =
  # The c42 object / singleton / root types should allow something
  # like:
  #
  # exclusions { field1: field2, field2: field3 }
  if fieldName1 notin sect.fields:
    defErr(sect, fmt"{fieldName1} must exist in section {sect.typeName}" &
                    " before it can be used in an exclusion.")
  if fieldName2 notin sect.fields:
    defErr(sect, fmt"{fieldName2} must exist in section {sect.typeName}" &
                    " before it can be used in an exclusion.")
  var
    field1 = sect.fields[fieldName1]
    field2 = sect.fields[fieldName2]

  # Note: not checking for a double add here.
  field1.exclusions.add(fieldName2)
  field2.exclusions.add(fieldName1)

proc addSection*(sect:     Con4mSectionType,
                 typeName: string,
                 min:      int  = 0,
                 max:      int  = 0,
                 lock:     bool = false): Con4mSectionType {.discardable.} =

  let knownTypes = sect.backref.secSpecs

  if typeName notin knownTypes:
    defErr(sect, fmt"Reference an undeclared section type: {typeName}")
  if typeName in sect.fields:
    defErr(sect, fmt"Duplicate spec for: {typeName}")
  if min < 0 or max < 0:
    defErr(sect, fmt"Values for min and max must be positive")
  if max != 0 and min > max:
    defErr(sect, fmt"Minimum number can't be greater than the maximum")

  let t = knownTypes[typeName]

  if t.singleton and min > 1 or max > 1:
    defErr(sect, fmt"Section {typeName} is a singleton; min/max fields " &
                    "must be 1 or less")

  var fs = FieldSpec(extType:     ExtendedType(t),
                     minRequired: min,
                     maxRequired: max,
                     default:     none(Box),
                     lock:        lock,
                     doc:         sect.doc,
                     shortdoc:    sect.shortdoc,
                     hidden:      sect.hidden)
  sect.fields[typeName] = fs

proc newSpec*(): ConfigSpec =
  result = ConfigSpec()

  result.rootSpec = sectionType(result, "", true)

proc getRootSpec*(spec: ConfigSpec): Con4mSectionType =
  return spec.rootSpec

proc validateOneSectionPass1(attrs:  AttrScope,
                             spec:   Con4mSectionType,
                             c42Env: ConfigState)

proc validateOneSectionPass2(attrs:        AttrScope,
                             spec:         Con4mSectionType,
                             c42Env:       ConfigState,
                             defaultsOnly: bool)


proc exclusionPresent(attrs, name, spec: auto): string =
  # Returns any one exclusion from the spec that has a value
  # associated with it in attrs, whether it's an instantiated
  # section (even if empty) or another attribute.
  for item in spec.exclusions:
    if item == name:
      continue # Ignore if we excluded ourselves.
    if item notin attrs.contents:
      continue
    let aOrS = attrs.contents[item]
    if aOrS.isA(AttrScope):
      return item # Once present, attr objects never go away.
    let attr = aOrS.get(Attribute)
    if attr.attrToVal.isSome():
      return item
  return ""

proc validateOneSectFieldPass1(attrs:  AttrScope,
                               name:   string,
                               spec:   FieldSpec,
                               c42Env: ConfigState) =

  if name notin attrs.contents:
      return
  let aOrS = attrs.contents[name]
  if aOrS.isA(Attribute):
    specErr(attrs, fmt"Expected a section '{name}', but got an " &
                      "attribute instead.")
  let
    sectAttr = aOrS.get(AttrScope)
    secSpec = spec.extType.sinfo
  if secSpec.singleton:
    validateOneSectionPass1(sectAttr, secSpec, c42env)
    return
  for k, v in sectAttr.contents:
    if v.isA(Attribute):
      specErr(attrs, fmt"Cannot have a singleton for section type: '{name}'")
    else:
      validateOneSectionPass1(v.get(AttrScope), secSpec, c42env)


proc validateOneSectFieldPass2(attrs:        AttrScope,
                               name:         string,
                               spec:         FieldSpec,
                               c42Env:       ConfigState,
                               defaultsOnly: bool) =
  let exclusion = exclusionPresent(attrs, name, spec)

  if name notin attrs.contents:
    if not defaultsOnly and spec.minRequired > 0 and exclusion == "":
      specErr(attrs, fmt"Required section '{name}' is missing, and there " &
        "are no other fields present that would remove this constraint.")
    else:
      return

  let aOrS = attrs.contents[name]
  if aOrS.isA(Attribute):
    if defaultsOnly: return
    specErr(attrs, fmt"Expected a section '{name}', but got an " &
                      "attribute instead.")
  let
    sectAttr = aOrS.get(AttrScope)
    secSpec = spec.extType.sinfo
  if secSpec.singleton:
    validateOneSectionPass2(sectAttr, secSpec, c42env, defaultsOnly)
    return
  for k, v in sectAttr.contents:
    if v.isA(Attribute):
      if defaultsOnly: return
      specErr(attrs, fmt"Cannot have a singleton for section type: '{name}'")
    else:
      validateOneSectionPass2(v.get(AttrScope), secSpec, c42env, defaultsOnly)

  if defaultsOnly: return

  if exclusion != "":
    if len(sectAttr.contents) > 0:
      specErr(attrs, fmt"'{name}' cannot appear alongside '{exclusion}'")
  else:
    if len(sectAttr.contents) < spec.minRequired:
      specErr(attrs, fmt"Expected {spec.minRequired} sections of '{name}', " &
                     fmt"but only have {len(sectAttr.contents)}.")
    if spec.maxRequired != 0 and len(sectAttr.contents) > spec.maxRequired:
      specErr(attrs, fmt"Expected no more than {spec.minRequired} sections " &
                     fmt"of '{name}', but got {len(sectAttr.contents)}.")

var validatorsToRun: seq[(CallbackObj, Attribute, seq[Box])] = @[]

proc validateOneAttrFieldPass1(attrs:  AttrScope,
                               name:   string,
                               spec:   FieldSpec,
                               c42Env: ConfigState) {.inline.} =
  if name notin attrs.contents: return
  let aOrS = attrs.contents[name]
  if aOrS.isA(AttrScope):
    specErr(attrs, fmt"Expected a field '{name}' but got a section instead.")


proc validateOneAttrFieldPass2(attrs:        AttrScope,
                               name:         string,
                               spec:         FieldSpec,
                               c42Env:       ConfigState,
                               defaultsOnly: bool) =
  let exclusion = exclusionPresent(attrs, name, spec)

  if name notin attrs.contents:
    if spec.minRequired == 1 and exclusion == "":
      if spec.default.isSome():
        let t = spec.extType.tinfo
        # While we set the default here, it does have to drop down
        # below to properly type check.
        attrs.contents[name] = Attribute(name: name,
                                         scope: attrs,
                                         tInfo: t,
                                         value: spec.default,
                                         override: none(Box))
      elif not defaultsOnly:
        specErr(attrs, fmt"Inside field '{attrs.name}': Required attribute " &
                       fmt"'{name}' is missing, and there are no other " &
                          "fields present that would remove this constraint.")
    else:
      return

  if defaultsOnly: return
  let
    aOrS = attrs.contents[name]
    attr = aOrS.get(Attribute)
  if not attr.attrToVal().isSome() and spec.minRequired == 1:
    if exclusionPresent(attrs, name, spec) == "":
      if spec.default.isSome():
        attr.value = spec.default
      else:
        specErr(attr, fmt"Required attribute '{name}' is missing.")
  elif exclusion != "":
      specErr(attr, fmt"'{name}' can't appear alongside '{exclusion}'")

  case spec.extType.kind
  of TypePrimitive:
    if attr.tInfo.unify(spec.extType.tinfo.copyType()).isBottom():
      let
        specType = $(spec.extType.tinfo)
        attrType = $(attr.tInfo)

      specErr(attr, fmt"Wrong type for '{name}' (spec said " &
        $color(fmt"{specType} ", "green") &
        "but value is a: " & $color(fmt"{attrType}", "green") & ")")


    var attrVal = attr.attrToVal()
    if attrVal.isSome():
      if spec.extType.range.low != spec.extType.range.high:
        assert not attr.tInfo.unify(intType).isBottom()
        let val = unpack[int](attrVal.get())
        if val < spec.extType.range.low or val > spec.extType.range.high:
          specErr(attr, fmt"Value '{val}' is outside of allowed range: " &
                  fmt"{spec.extType.range.low} .. {spec.extType.range.high}")
      elif len(spec.extType.intChoices) != 0:
        assert not attr.tInfo.unify(intType).isBottom()
        let val = unpack[int](attrVal.get())
        if val notin spec.extType.intChoices:
          specErr(attr, "Value is not one of the valid choices: " &
            $(spec.extType.intChoices))
      elif len(spec.extType.strChoices) != 0:
        assert not attr.tInfo.unify(stringType).isBottom()
        let val = unpack[string](attrVal.get())
        if val notin spec.extType.strChoices:
          specErr(attr, "Value is not one of the valid choices: " &
            spec.extType.strChoices.join(", "))
      elif spec.extType.itemCount.low != 0 or spec.extType.itemCount.high != 0:
        var l: int
        case attr.tInfo.getBaseType()
        of TypeDict:
          let val = unpack[OrderedTableRef[Box, Box]](attrVal.get())
          l   = len(val)
        of TypeList:
          let val = unpack[seq[Box]](attrVal.get())
          l   = len(val)
        else:
          specErr(attr, "Value must be a container.")

        if spec.extType.itemCount.low > 0:
          if l < spec.extType.itemCount.low:
            specErr(attr, "Value is require to contain between at least " &
              $(spec.extType.itemCount.low) & " values")
        if spec.extType.itemCount.high > 0:
          if l > spec.extType.itemCount.high:
            specErr(attr, "Value is require to contain no more than " &
              $(spec.extType.itemCount.low) & " values")

  of TypeSection:
    unreachable
  of TypeC4TypeSpec:
    discard # Only the referrer needs to validate.
  of TypeC4TypePtr:
    let fieldRef = spec.extType.fieldRef

    if fieldRef notin attrs.contents:
      specErr(attrs, fmt"Type for field '{name}' is supposed to be taken " &
                     fmt"from the '{fieldRef}' field, which was not provided.")

    let refAOrS = attrs.contents[fieldRef]
    if refAOrS.isA(AttrScope):
      specErr(attrs, fmt"Expected a field named '{fieldRef}' containing " &
                     fmt"the type for the field '{name}'")

    let refAttr = refAOrS.get(Attribute)
    if not refAttr.attrToVal().isSome():
      specErr(attrs, fmt"Field '{fieldRef}' is supposed to contain a " &
                     fmt"con4m type for field '{name}', but that type is " &
                        "missing.")
    if refAttr.tInfo.unify(newTypeSpec()).isBottom():
      specErr(attrs, fmt"Field '{fieldRef}' is supposed to contain a con4m " &
                     fmt"type for field '{name}', but the field is not a " &
                     "valid con4m string.")
    let fieldT = unpack[Con4mType](refAttr.attrToVal().get())
    try:
      if attr.tInfo.unify(fieldT).isBottom():
        specErr(attrs, fmt"Wrong type for {name} (expected {`$`(fieldT)} per " &
                       fmt"the type read from field '{fieldRef}'), but got: " &
                       fmt"{`$`(attr.tInfo)}")
    except:
      specErr(attrs, fmt"When reading a type from field '{fieldRef}' " &
                     fmt"(to type check the field '{name}'), got a parse " &
                     "error parsing the type: " & getCurrentExceptionMsg())

  if spec.lock:
    if attr.value.isSome():
      attr.locked = true
    else:
     attr.lockOnWrite = true
  if spec.stackLimit != -1:
    if getReplacementState().get().numExecutions >= spec.stackLimit:
      attr.locked = true

  if spec.extType.validator != nil and attr.attrToVal().isSome():
    var fieldType: Con4mType
    if spec.extType.kind in [TypePrimitive, TypeC4TypeSpec]:
      fieldType = spec.extType.tinfo.resolveTypeVars()
    else:
      fieldType = stringType

    if c42env == nil:
      specErr(attr, "A validator was specified, but the application " &
                    "didn't provide an evaluation context.")
    else:
      let args = @[pack(attr.fullNameAsStr()), attr.attrToVal().get()]
      validatorsToRun.add((spec.extType.validator, attr, args))

proc validateOneSectionPass1(attrs:  AttrScope,
                        spec:   Con4mSectionType,
                        c42Env: ConfigState) =
  # Here we are 'in' a section and need to validate each field.
  for name, fieldspec in spec.fields:
    if fieldspec.extType.kind == TypeSection:
      validateOneSectFieldPass1(attrs, name, fieldspec, c42env)
    else:
      validateOneAttrFieldPass1(attrs, name, fieldspec, c42env)

  if "*" notin spec.fields:
    # You can't dynamically add field sets right now, so this can
    # 100% be checked statically.  The second you can, we need to move this.
    for name, _ in attrs.contents:
      if name notin spec.fields:
        specErr(fmt"Unknown field for a {spec.typeName} section: {name}")

proc validateOneSectionPass2(attrs:        AttrScope,
                             spec:         Con4mSectionType,
                             c42Env:       ConfigState,
                             defaultsOnly: bool) =
  # Here we are 'in' a section and need to validate each field.
  for name, fieldspec in spec.fields:
    if fieldspec.extType.kind == TypeSection:
      validateOneSectFieldPass2(attrs, name, fieldspec, c42env, defaultsOnly)
    else:
      validateOneAttrFieldPass2(attrs, name, fieldspec, c42env, defaultsOnly)

  if not defaultsOnly and spec.validator != nil:
    let ret = c42env.sCall(spec.validator.name, @[pack(attrs.fullNameAsStr())],
                          spec.validator.tInfo)
    if ret.isNone():
        specErr(attrs, "A validator was specified, but no function of the " &
                fmt"correct type is in spec file: {$(spec.validator)}")
    let errMsg = unpack[string](ret.get())

    if errMsg != "": specErr(attrs, errMsg)

proc runCallbacks(spec: ConfigState, env: ConfigState) =
  for (validator, attr, args) in validatorsToRun:
      let ret = env.sCall(validator.name, args, validator.tInfo)
      if ret.isNone():
        specErr(attr, "A validator was specified, but no function of the " &
                fmt"correct type is in spec file: {$validator}")
      let
        errMsg = unpack[string](ret.get())

      if errMsg != "":
        specErr(attr, errMsg)

  validatorsToRun = @[]

  let
    tInfo = newProcType(@[], stringType)
    cbres = env.scall("final_check", seq[Box](@[]), tInfo)

  if cbres.isSome():
    let msg = unpack[string](cbres.get())
    if msg != "": specErr(msg)

proc validateState*(state: ConfigState, c42env: ConfigState = nil) =
  ## This is the post-evaluation validation routine.  There used to
  ## only be one evaluation point-- after the execution. However, we
  ## have moved anything that can be checked prior to execution to
  ## happen then.  Specificially, we do type checking of attributes
  ## there Constraints are all checked in the second pass.
  ##
  ## Once we are doing proper code generation, as much checking as we
  ## can do pre-execution, the better, but right now, most of it is
  ## happening post-execution.  And, note that, as we add the ability
  ## to dynamically set fields, we will have a harder time pushing
  ## things to compile-time.

  # The 'replacement state' is basically to enable things like the
  # sections() builtin in a con4m-to-spec scenario-- specifically, the
  # code in a con4m spec can check the sections of the NEW spec we're
  # creating.  Also, we use this stash above to avoid passing state as
  # an extra variable all around.
  #
  # This all will need to change a bit if we ever allow real
  # multi-threading (TODO).

  setReplacementState(state)
  validateOneSectionPass2(state.attrs, state.spec.get().rootSpec, c42env, false)
  if c42env != nil: state.runCallbacks(c42env)
  clearReplacementState()

proc setDefaults*(state: ConfigState, c42env: ConfigState) =
  ## If we are so sure of our code's correctness, but the spec had
  ## default: ... values, this allows us to then cause defaults to be
  ## set, so that subsequent queries can work right :)
  validateOneSectionPass2(state.attrs, state.spec.get().rootSpec, c42env, true)

proc basicSanityCheck*(state: ConfigState, c42env: ConfigState = nil)
    {.inline.} =
  validateOneSectionPass1(state.attrs, state.spec.get().rootSpec, c42env)

proc getDocableSecs*(state: ConfigState): seq[Con4mSectionType] =
  result = @[]

  if not state.spec.isSome(): return

  for _, sec in state.spec.get().secSpecs:
    if not sec.hidden: result.add(sec)

proc getSection*(state: ConfigState, name: string): Option[Con4mSectionType] =
  if not state.spec.isSome(): return none(Con4mSectionType)
  if name == "": return some(state.spec.get().rootSpec)
  if name notin state.spec.get().secSpecs: return none(Con4mSectionType)
  return some(state.spec.get().secSpecs[name])

proc getDocableFields*(sec: Con4mSectionType): seq[(string, FieldSpec)] =
  result = @[]

  for name, fieldspec in sec.fields:
    if not fieldspec.hidden: result.add((name, fieldspec))

proc getFieldDocStr*(field: FieldSpec): Option[string] = return field.doc

proc getSectionDocStr*(state: ConfigState, name: string): Option[string] =
  let section = state.getSection(name).getOrElse(nil)
  if section == nil: return none(string)
  return section.doc

proc getSectionShortDocStr*(state: ConfigState, name: string): Option[string] =
  let section = state.getSection(name).getOrElse(nil)
  if section == nil: return none(string)
  return section.shortdoc

proc getFieldSpec*(state: ConfigState,
                   scope: string,
                   name:  string): Option[FieldSpec] =
  if not state.spec.isSome(): return none(FieldSpec)
  let secSpecs = state.spec.get().secSpecs

  if scope notin secSpecs: return none(FieldSpec)
  if name notin secSpecs[scope].fields: return none(FieldSpec)

  return some(secSpecs[scope].fields[name])

proc reprFieldProps*(field: FieldSpec): string =
  var parts: seq[string] = @[]

  if field.minRequired == 1: parts.add("required")
  if field.lock:             parts.add("write-once")
  if field.stackLimit != -1: parts.add("locks after " & $(field.stackLimit) &
                                       " stacks")
  case field.extType.kind
  of TypePrimitive:
    if (field.extType.range.low != field.extType.range.high) or
      field.extType.range.low > 0:
      parts.add("range " & $(field.extType.range.low) & ".." &
                $(field.extType.range.high))
    elif (field.extType.itemCount.low != field.extType.range.high) or
      field.extType.range.low > 0:
      parts.add("# items " & $(field.extType.itemCount.low) & ".." &
                $(field.extType.itemCount.high))
    elif len(field.extType.intChoices) != 0:
      parts.add("choices: " & $(field.extType.intChoices))
    elif len(field.extType.strChoices) != 0:
      parts.add("choices: " & $(field.extType.strChoices))
  of TypeC4TypePtr:
    parts.add("gets type from field '"  & field.extType.fieldRef & "'")
  else:
    discard

  return parts.join(", ")

proc reprDefaultValue*(field: FieldSpec): string =
  if field.default.isNone(): return "<none>"
  return oneArgToString(field.extType.tInfo, field.default.get(), vtNoLits)

# TODO, allow me to query allow/requires, user_def_okay, exclusions, ...
proc reprType*(field: FieldSpec): string =
  case field.extType.kind
  of TypePrimitive:  return  $(field.extType.tInfo)
  of TypeC4TypeSpec: return "typespec"
  of TypeSection:    return "section"
  of TypeC4TypePtr:  return "type pointer"



type Con4mDocXform*  = (string) -> string
type
  Con4mRowFilter*    = (seq[string]) -> bool
  XFormTable         = TableRef[string, Con4mDocXform]

let defaultObjDoc = @[fcName, fcLong, fcType, fcDefault, fcProps]

proc defaultCmp(x, y: seq[string]) : int =
  system.cmp(x, y)
