## Our implementation of the good ol' unifcation algorithm, with
## Con4m's current type rules codified.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022

import types, tables, options, nimutils, dollars


proc copyType*(t: Con4mType): Con4mType

# This should only be called when we know that the type variable
# is going to be unique for the context.  It's mainly meant
# for compile-time usage.
proc newTypeVar*(num: int): Con4mType =
  return Con4mType(kind: TypeTVar, varNum: num)
proc newTypeSpec*(): Con4mType =
  return Con4mType(kind: TypeTypeSpec, binding: newTypeVar())
proc newListType*(contained: Con4mType): Con4mType =
  return Con4mType(kind: TypeList, itemType: contained)
proc newDictType*(keyType, valType: Con4mType): Con4mType =
  return Con4mType(kind: TypeDict, keyType: keyType, valType: valType)
proc genericList*(): Con4mType = newListType(newTypeVar())
proc genericDict*(): Con4mType = newDictType(newTypeVar(), newTypeVar())
proc anyTuple*():    Con4mType = Con4mType(kind: TypeTuple, itemTypes: @[])
proc newProcType*(params:  seq[Con4mType],
                  retType: Con4mType,
                  va:      bool = false): Con4mType =
  if params.len() != 0:
    return Con4mType(kind: TypeFunc, params: params, va: va, retType: retType)
  else:
    return Con4mType(kind: TypeFunc, retType: retType)

proc linkTypeVar(t1: Con4mType, t2: Con4mType) =
  if t1 == t2: return
  if t2.kind == TypeTVar:
    t2.linksin.add(t1)
    t1.link = some(t2)
    for item in t1.linksin:
      item.link = some(t2)
      t2.linksin.add(item)
  else:
    t1.link = some(t2)
    for item in t1.linksin:
      item.link = some(t2)

  t1.linksin = @[]

proc getBaseType*(t: Con4mType): Con4mTypeKind =
  if t.kind == TypeTVar:
    if t.link.isSome(): return t.link.get().getBaseType()
    return TypeTVar
  else:
    return t.kind

proc getBaseType*(node: Con4mNode): Con4mTypeKind =
  return node.typeInfo.getBaseType()

proc isBottom*(t: Con4mType): bool = return t.kind == TypeBottom

# Uncomment this if you need a trace of unify() calls,
# rename unify below to unifyactual, and then
# uncomment the debug wrapper for unify below.
# proc unify*(param1: Con4mType, param2: Con4mType): Con4mType
proc unify*(param1: Con4mType, param2: Con4mType): Con4mType {.inline.} =
  let
    t1 = param1.resolveTypeVars()
    t2 = param2.resolveTypeVars()

  if t2.kind == TypeTVar and t1.kind != TypeTVar:
    return t2.unify(t1) # autocast will be irrelevant here.

  case t1.kind
  # Just in case someone manages to clone a singleton, we
  # always check against the .kind field, instead of looking at
  # object equivolence for singletons (e.g., int, bottom)
  of TypeString, TypeBool, TypeInt, TypeFloat, TypeChar, TypeDuration,
     TypeIPAddr, TypeCIDR, TypeSize, TypeDate, TypeTime, TypeDateTime:
    if t2.kind == t1.kind: return t1
    return bottomType
  of TypeBottom: return bottomType
  of TypeTypeSpec:
    if t2.kind != TypeTypeSpec:
      return bottomType
    let
      bindtype1 = t1.binding.resolveTypeVars()
      bindtype2 = t2.binding.resolveTypeVars()

    # If both type specs are void, the unify returns bottom, since void
    # and bottom are generally the same thing.
    if bindtype1.kind == bindtype2.kind and bindtype1.isBottom():
      return t1

    # Same thing is true if one side is a type variable that might bind to
    # a void.
    if bindtype1.isBottom() and bindtype2.kind == TypeTVar and
       len(bindtype2.components) == 0:
      return t1

    if bindtype2.isBottom() and bindtype1.kind == TypeTVar and
       len(bindtype1.components) == 0:
      return t2

    return bindtype1.unify(bindtype2)
  of TypeFunc:
    if t2.kind != TypeFunc: return bottomType
    if t2.noSpec: return t1
    if t1.noSpec: return t2
    var
      newParams: seq[Con4mType]
      newRet:    Con4mType
      vaResult:  bool

    # Actuals will never be varargs, so if we have two vararg
    # functions, it's only because we're trying to unify two formals.
    if ((not t1.va) and (not t2.va)) or (t1.va and t2.va):
      if t1.params.len() != t2.params.len(): return bottomType
      for i in 0 ..< t1.params.len():
        let p = t1.params[i].unify(t2.params[i])

        if p.kind == TypeBottom: return bottomType
        newParams.add(p)
      if t1.va: vaResult = true
    else:
      if t1.va:
        vaResult = true
        if t2.params.len() < t1.params.len() - 1: return bottomType
        for i in 0 ..< t1.params.len() - 1:
          let p = t1.params[i].unify(t2.params[i])
          if p.kind == TypeBottom: return bottomType
          newParams.add(p)
        var vargType: Con4mType = t1.params[^1]
        for i in t1.params.len()-1 ..< t2.params.len():
          vargType = vargType.unify(t2.params[i])
          if vargType.kind == TypeBottom: return bottomType
        newParams.add(vargType)
      else:
        return t2.unify(t1)

    newRet = t1.retType.unify(t2.retType)
    if newRet.kind == TypeBottom:
      if not (t1.retType.kind in [TypeBottom, TypeTVar]) or
         not (t2.retType.kind in [TypeBottom, TypeTVar]):
        return bottomType

    return newProcType(newParams, newRet, vaResult)
  of TypeTuple:
    # If a tuple has no item types, then this is "any tuple", which
    # can only be specified in the context of an internal type
    # constraint.
    if t2.kind != TypeTuple:     return bottomType
    elif len(t1.itemTypes) == 0: return t2
    elif len(t2.itemTypes) == 0: return t1
    elif len(t2.itemTypes) != len(t1.itemTypes): return bottomType
    result = Con4mType(kind: TypeTuple, itemTypes: @[])
    for i, item in t1.itemTypes:
      let l = unify(item, t2.itemTypes[i])
      if l.kind == TypeBottom:
        return bottomType
      result.itemTypes.add(l)
    return
  of TypeList:
    if t2.kind != TypeList: return bottomType
    let containedType = t1.itemType.unify(t2.itemType)
    if containedType == bottomType: return bottomType
    return newListType(containedType)
  of TypeDict:
    if t2.kind != TypeDict: return bottomType
    let kt = t1.keyType.unify(t2.keyType)
    let vt = t1.valType.unify(t2.valType)
    if kt.kind == TypeBottom or vt.kind == TypeBottom: return bottomType
    return newDictType(kt, vt)
  of TypeTVar:
    if t2.kind != TypeTVar:
      if len(t1.components) != 0:
        for item in t1.components:
          let v = item.copyType().unify(t2.copyType())
          if not v.isBottom():
            t1.linkTypeVar(t2)
            return t2
        return bottomType
      else:
        t1.linkTypeVar(t2)
        return t2
    elif len(t1.components) == 0:
      t1.linkTypeVar(t2)
      return t2
    elif len(t2.components) == 0:
      t2.linkTypeVar(t1)
      return t1
    # Here, both types are constrained, so we need to compute the
    # intersection.
    var foundTypes: seq[Con4mType] = @[]
    for t1item in t1.components:
      for t2item in t2.components:
        let res = t1item.unify(t2item)
        if not res.isBottom():
          foundTypes.add(t2item)
          break
    case len(foundTypes)
    of 0:
      return bottomType
    of 1:
      t1.linkTypeVar(foundTypes[0])
      t2.linkTypeVar(foundTypes[0])
    else:
      t1.components = foundTypes
      t2.linkTypeVar(t1)
    return t1

# If you need a trace of unify calls, follow the instructions above, then
# uncomment the blow wrapper.
# import strformat
# proc unify*(param1: Con4mType, param2: Con4mType): Con4mType =
#  let
#    s1 = $(param1)
#    s2 = $(param2)
#  result = unifyActual(param1, param2)
#  echo fmt"{s1} ⋃ {s2} = {`$`(result)}"

proc isBottom*(t1, t2: Con4mType): bool = return unify(t1, t2).isBottom()

proc unify*(n2, n1: Con4mNode): Con4mType =
  return unify(n1.typeInfo, n2.typeInfo)

proc isBottom*(n: Con4mNode): bool = return n.typeInfo.isBottom()

proc isBottom*(n1, n2: Con4mNode): bool =
  return isBottom(n1.typeInfo, n2.typeInfo)

proc isBottom*(n: Con4mNode, t: Con4mType): bool =
  return isBottom(n.typeInfo, t)

proc hasTypeVar*(t: Con4mType): bool =
  case t.kind
  of TypeTVar, TypeTypeSpec:
    # Doesn't matter if it's a forward, return true and
    # get a clean copy!
    return true
  of TypeList:
    return t.itemType.hasTypeVar()
  of TypeDict:
    return t.keyType.hasTypeVar() or t.valType.hasTypeVar()
  of TypeTuple:
    for item in t.itemTypes:
      if item.hasTypeVar(): return true
  of TypeFunc:
    if t.nospec: return false
    for item in t.params:
      if item.hasTypeVar(): return true
    return t.retType.hasTypeVar()
  else:
    return false

proc copyType*(t: Con4mType, cache: TableRef[int, Con4mType]): Con4mType =
  if not t.hasTypeVar(): return t

  case t.kind
  of TypeTVar:
    if t.varNum in cache:
      return cache[t.varNum]
    if t.link.isSome():
      let n    = t.varNum
      result   = t.resolveTypeVars().copyType(cache)
      cache[n] = result
    else:
      result          = newTypeVar(t.components)
      result.cycle    = false
      cache[t.varNum] = result
      for item in t.components:
        result.components.add(item.copyType(cache))
    if result.kind == TypeTVar:
      result.localName = t.localName
  of TypeTypeSpec:
    result = Con4mType(kind: TypeTypeSpec, binding: t.binding.copyType(cache))
  of TypeList:
    result = Con4mType(kind: TypeList)
    result.itemType = t.itemType.copyType(cache)
  of TypeDict:
    result = Con4mType(kind: TypeDict)
    result.keyType = t.keyType.copyType(cache)
    result.valType = t.valType.copyType(cache)
  of TypeTuple:
    result = Con4mType(kind: TypeTuple)
    for param in t.itemTypes:
      result.itemTypes.add(param.copyType(cache))
  of TypeFunc:
    result = Con4mType(kind: TypeFunc)
    for param in t.params:
      result.params.add(param.copyType(cache))
    result.va = t.va
    result.retType = t.retType.copyType(cache)
  else: unreachable

proc copyType*(t: Con4mType): Con4mType =
  var tVarCache = newTable[int, Con4mType]()
  return t.copytype(tVarCache)

proc reprSig*(name: string, t: Con4mType): string = return name & $(t)


proc getBoxType*(b: Box): Con4mType =
  case b.kind
  of MkStr:   return stringType
  of MkInt:   return intType
  of MkFloat: return floatType
  of MkBool:  return boolType
  of MkSeq:
    var itemTypes: seq[Con4mType]
    let l = unpack[seq[Box]](b)

    if l.len() == 0:
      return newListType(newTypeVar())

    for item in l:
      itemTypes.add(item.getBoxType())
    for item in itemTypes[1..^1]:
      if item.unify(itemTypes[0]).isBottom():
        return Con4mType(kind: TypeTuple, itemTypes: itemTypes)
    return newListType(itemTypes[0])
  of MkTable:
    # This is a lie, but con4m doesn't have real objects, or a "Json" / Mixed
    # type, so we'll just continue to special case dicts.
    return newDictType(stringType, newTypeVar())
  else:
    return newTypeVar() # The JSON "Null" can stand in for any type.

proc checkAutoType*(b: Box, t: Con4mType): bool =
  return not b.getBoxType().unify(t).isBottom()
