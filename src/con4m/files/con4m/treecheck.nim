## This module is doing three things:
##
## 1) Type-checking the program, using the standard unifcation
##    algorithm, which itself lives in typecheck.nim
##
## 2) Puttixng symbol tables into each node, inserting variables (and
##    constants) into the proper symbol tables as it goes.
##
## 3) Setting values from simple literals.  Dict/list literals are
##    done at eval time.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022

import math, options, strformat, strutils, tables, nimutils
import errmsg, types, st, parse, otherlits, typecheck, dollars, components

const allLiteralTypes = [ NodeSimpLit, NodeDictLit, NodeListLit, NodeTupleLit,
                         NodeCallbackLit ]

proc isConstLit(node: Con4mNode): bool =
  if node.isConst:
    return true
  case node.kind
  of NodeSimpLit, NodeType, NodeCallbackLit:
    node.isConst = true
    return true
  of NodeListLit, NodeTupleLit, NodeDictLit, NodeKvPair:
    for kid in node.children:
      if not kid.isConstLit:
        return false
    node.isConst = true
    return true
  else:
    return false

proc addPlaceHolder(s: ConfigState, name: string) =
  let f = FuncTableEntry(kind:        FnUserDefined,
                         tinfo:       bottomType,
                         name:        name,
                         impl:        none(Con4mNode),
                         onStack:     false,
                         cannotCycle: false,
                         locked:      false)
  if name in s.funcTable:
    s.funcTable[name].add(f)
  else:
    s.funcTable[name] = @[f]
  s.waitingForTypeInfo = true

proc nodeToStringLit(node: Con4mNode): Box =
  node.typeInfo = stringType
  var s = node.getTokenText()
  return pack(s)

proc nodeToCharLit(node: Con4mNode): Box =
  node.typeInfo = charType
  return  pack(node.token.get().codepoint)

proc nodeToIntLit(node: Con4mNode): Box =
  node.typeInfo = intType
  try:
    result = pack(node.getTokenText().parseInt())
  except:
    fatal("Number too large for int type.", node)

proc nodeToTrueLit(node: Con4mNode): Box =
  node.typeInfo = boolType
  result        = pack(true)

proc nodeToFalseLit(node: Con4mNode): Box =
  node.typeInfo = boolType
  result        = pack(false)

proc nodeToFloatLit(node: Con4mNode): Box =
  node.typeInfo = floatType

  let
    txt = node.getTokenText()
    dotLoc = txt.find('.')
  var
    eLoc = txt.find('e')
    value:        float
    intPartS:     string
    intPartI:     int
    floatPartS:   string
    expPartS:     string
    expPartI:     int    = 0
    eSignIsMinus: bool

  if eLoc == -1:
    eLoc = txt.find('E')

  if dotLoc != -1:
    intPartS = txt[0 ..< dotLoc]
    if eLoc != -1:
      floatPartS = txt[dotLoc+1 ..< eLoc]
    else:
      floatPartS = txt[dotLoc+1 .. ^1]
  else:
    intPartS = txt[0 ..< eLoc]

  if eLoc != -1:
    eLoc = eLoc + 1
    case txt[eLoc]
    of '+':
      eLoc = eLoc + 1
    of '-':
      eLoc = eLoc + 1
      eSignIsMinus = true
    else:
      discard
    expPartS = txt[eLoc .. ^1]

  try:
    intPartI = intPartS.parseInt()
  except:
    fatal("Integer piece is too large for an int; use 'e' notation.", node)

  if expPartS != "":
    try:
      expPartI = expPartS.parseInt()
    except:
      fatal("Exponent piece of float overflows integer type", node)

  # Fow now, we just truncate floating point digits if there are
  # $(high(int)).len() digits or more.

  if floatPartS != "":
    const
      maxAsString = $(high(int))
      maxLen = maxAsString.len()

    if floatPartS.len() >= maxLen:
      floatPartS = floatPartS[0 ..< maxLen]

    value = floatPartS.parseInt() / (10 ^ floatPartS.len())

  value = value + float(intPartI)
  value = value * pow(10.0, float(expPartI))

  return pack(value)

proc nodeToOtherLit(node: Con4mNode): Box =
  var txt = node.getTokenText()
  if len(txt) >= 4 and txt[0..1] == "<<":
    txt = txt[2..^3]

  var opt = txt.otherLitToValue()

  if opt.isNone():
    fatal("Invalid literal: <<" & txt & ">>")

  (result, node.typeInfo) = opt.get()

proc nodeToSimpLit(node: Con4mNode): Box =
  case node.token.get().kind:
    of TtStringLit:
      return node.nodeToStringLit()
    of TtCharLit:
      return node.nodeToCharLit()
    of TtOtherLit:
      return node.nodeToOtherLit()
    of TtIntLit:
      return node.nodeToIntLit()
    of TtFloatLit:
      return node.nodeToFloatLit()
    of TtTrue:
      return node.nodeToTrueLit()
    of TtFalse:
      return node.nodeToFalseLit()
    else:
      unreachable

proc findMatchingProcs*(s:          ConfigState,
                        name:       string,
                        tInfo:      Con4mType): seq[FuncTableEntry] =
  result = @[]

  if name notin s.funcTable:
    # Can only happen on the first pass!
    s.addPlaceHolder(name)
    return

  for item in s.funcTable[name]:
    if not unify(tInfo.copyType(), item.tInfo.copyType()).isBottom():
      if (item.kind != FnBuiltIn) and item.impl.isNone(): continue
      result.add(item)

  if len(s.funcTable[name]) == 0 and not s.secondpass:
    s.addPlaceHolder(name)

proc ensureCallbackImplementationExists*(s: ConfigState, cbObj: CallbackObj) =
  let
    candidates = s.findMatchingProcs(cbObj.name, cbObj.tInfo)

  if len(candidates) == 0:
    fatal("Could not find an implementation of the callback:  " & $(cbobj))

proc fatal2Type(err: string, n: Con4mNode, t1, t2: Con4mType) =
  let extra = fmt" ('{`$`(t1)}' vs '{`$`(t2)}')"

  fatal(err & extra, n)

proc addFuncDef(s: ConfigState, fd: FuncTableEntry): bool =
  # This func detects adding duplicates; but we only need it to run on the
  # first pass.  On the second pass we want to ignore it.
  if s.secondPass:
    return true
  for item in s.moduleFuncDefs:
    if fd.name != item.name: continue
    if isBottom(copyType(fd.tinfo), copyType(item.tinfo)): continue
    return false
  s.moduleFuncDefs.add(fd)
  return true

proc checkNode(node: Con4mNode, s: ConfigState)

proc checkKids(node: Con4mNode, s: ConfigState) {.inline.} =
  for item in node.children:
    item.checkNode(s)

proc binOpTypeCheck(node: Con4mNode,
                    constraints: seq[Con4mType],
                    s: ConfigState,
                    e1, e2: string) =
  node.checkKids(s)
  let
    tv = newTypeVar(constraints)
    paramCheck = unify(node.children[0], node.children[1])

  if paramCheck.isBottom():
    fatal2Type(e1, node, node.children[0].getType(), node.children[1].getType())

  node.typeInfo = unify(tv, paramCheck)

  if node.typeInfo.isBottom(): fatal2Type(e2, node, tv, paramCheck)

template pushVarScope() =
  if not s.secondPass: # Current value was already copied from parent
    node.varScope = VarScope(parent: some(node.varScope))

when defined(disallowRecursion):
  proc cycleDetected(stack: var seq[FuncTableEntry]) =
    let
      toMatch = stack[^1]
    var
      msg = "Function call cycle detected (disallowed): "
      parts: seq[string]

    for item in stack:
      if len(parts) == 0:
        if item != toMatch:
          continue
      parts.add(reprSig(item.name, item.tinfo))

    msg = msg & parts.join(" calls ")
    raise newException(Con4mError, msg)

  proc cyCheckOne(s: ConfigState, n: Con4mNode, stack: var seq[FuncTableEntry])

  proc cycleDescend(s: ConfigState,
                    n: Con4mNode,
                    stack: var seq[FuncTableEntry]) =
    if n.kind != NodeCall:
      for kid in n.children:
        cycleDescend(s, kid, stack)
    else:
      let fname = n.children[0].getTokenText()
      if fname in s.funcTable:
        let entries = s.funcTable[fname]
        for item in entries:
          if item.kind == FnBuiltIn:
            return
          let t = unify(n.children[1].getType(), item.tinfo)
          if not t.isBottom():
            stack.add(item)
            # This must be present if checking passed.
            let node = item.impl.get()
            cyCheckOne(s, node, stack)

  proc cyCheckOne(s: ConfigState, n: Con4mNode, stack: var seq[
      FuncTableEntry]) =
    if stack[^1].onStack:
      cycleDetected(stack)

    stack[^1].onStack = true
    cycleDescend(s, n, stack)
    stack[^1].onStack = false
    stack[^1].cannotCycle = true
    discard stack.pop()

    # We are going to add functions that get defined in this module to
    # the list of things to check for cycles.  We use the
    # "onStack" field to track all possible call stacks, and if
    # we go to push a function that is already on the stack, we
    # know there's a cycle.

    # Note that, when we allow function definitions to be shadowed, it
    # is possible to introduce cross-config file cycles that aren't
    # detectable just by looking at one file.
    #
    # To deal with such a case, we need to peer into the implementations
    # of called functions from other config files we've loaded.  But, we
    # only need to do that when they are called locally, we don't need
    # to use them as starting points, just the functions defined
    # locally.
    #
    # We also assume that built-in functions do NOT call back directly
    # into config code. That would defeat the purpose of callbacks. If
    # you break that rule, then all bets are off!
  proc cycleCheck(s: ConfigState) =
    var stack: seq[FuncTableEntry]

    for item in s.moduleFuncDefs:
      if item.cannotCycle:
        continue
      else:
        stack = @[item]
        # If we got here, item.impl must exist.
        s.cyCheckOne(item.impl.get(), stack)

proc getTokenType(node: Con4mNode): Con4mTokenKind {.inline.} =
  let token = node.token.get()

  return token.kind

proc nameConflictCheck(node:    Con4mNode,
                       name:    string,
                       s:       ConfigState,
                       allowed: openarray[UseCtx]): UseCtx {.discardable.} =
  result = node.nameUseContext(name, s)

  if result notin allowed:
    let msg = fmt"Can't re-define name {name}: Conflicts with existing "

    case result
    of ucFunc:
      fatal(msg & "function")
    of ucAttr:
      fatal(msg & "in-scope attribute")
    of ucVar:
      fatal(msg & "variable")
    else:
      discard

proc lhsIdCheck(s, name, node, tinfo, lhsNode, rhsNode: auto) =
  if not s.secondPass:
    if name == "result" and not s.funcOrigin:
      fatal("Cannot assign to special variable 'result' outside a function " &
              "definition.")

      node.nameConflictCheck(name, s, [ucVar, ucNone])
    let
      entry = node.addVariable(name)
      t     = unify(tinfo, entry.tinfo)

    if entry.locked:
      # Could be a loop index or enum.
        fatal(fmt"Cannot assign to the (locked) value {name}", lhsNode)

    if t.isBottom():
      fatal2Type(fmt"Assignment of {name} doesn't match its previous type",
                 rhsNode, tinfo, entry.tinfo)
    entry.tinfo = t

proc checkNode(node: Con4mNode, s: ConfigState) =
  # We take our scope from the parent by default.  If we're going to
  # have different scopes, the parent will tell us what our scope is.
  if node.varScope == nil:  node.varScope  = node.parent.get().varScope
  if node.attrScope == nil: node.attrScope = node.parent.get().attrScope

  case node.kind
  of NodeReturn:
    if not s.funcOrigin:
      fatal("Return not allowed outside function definition")
    if len(node.children) == 0:
      let
        entry = node.varUse("result").get()
      if entry.firstDef.isNone():
        if entry.tinfo != bottomType and entry.tinfo != nil:
          fatal("Return with no value, after a return with a value.", node)
        entry.tinfo = bottomType
    else:
      node.children[0].checkNode(s)
      let
        entry = node.varUse("result").get()
      if entry.firstDef.isNone():
        entry.tinfo = node.children[0].getType()
        entry.firstDef = some(node)
      else:
        let t = unify(entry.tinfo, node.children[0].getType())
        if t.isBottom():
          fatal2Type("Inconsistent return type for function",
                     node.children[0],
                     entry.tInfo,
                     node.children[0].getType())
        entry.tinfo = t
  of NodeEnum:
    if not s.secondPass:
      let tinfo = intType
      for i, kid in node.children:
        kid.varScope = node.varScope
        let name = kid.getTokenText()

        node.nameConflictCheck(name, s, [ucNone])

        let entry      = kid.addVariable(name)
        entry.value    = some(pack(i))
        entry.tinfo    = tinfo
        entry.persists = true
        entry.locked   = true
  of NodeSection:
    pushVarScope()
    if not s.secondPass:
      var
        scope   = node.attrScope
        secname = node.children[0].getTokenText()
        maybeEntry: AttrOrErr

      if s.funcOrigin:
        fatal("Cannot introduce a section within a function", node)

      node.nameConflictCheck(secname, s, [ucAttr, ucNone])

      if len(node.children) == 3:
        let objname = node.children[1].getTokenText()
        maybeEntry = scope.attrLookup([secname, objname], 0, vlSecDef)
      else:
        maybeEntry = scope.attrLookup([secname], 0, vlSecDef)

      if maybeEntry.isA(AttrErr):
        fatal(maybeEntry.get(AttrErr).msg, node)

      scope          = maybeEntry.get(AttrOrSub).get(AttrScope)
      node.attrScope = scope

    node.children[^1].checkNode(s)

  of NodeAttrAssign, NodeAttrSetLock:
    var nameParts: seq[string]
    # Deleted the restriction against assigning inside functions.
    if node.children[0].kind != NodeIdentifier:
      nameParts = @[]
      for child in node.children[0].children:
        nameParts.add(child.getTokenText())
    else:
      nameParts = @[node.children[0].getTokenText()]
    node.children[1].checkNode(s)
    let tinfo = node.children[1].getType()

    if not s.secondPass:
      for name in nameParts:
          if name == "result":
            fatal("'result' is a reserved word in con4m, and cannot be used " &
              "for attributes", node)

    let `existing?` = node.attrScope.attrLookup(nameParts, 0, vlAttrDef)
    if `existing?`.isA(AttrErr):
      fatal(`existing?`.get(AttrErr).msg, node)

    let entry = `existing?`.get(AttrOrSub).get(Attribute)
    if entry.tInfo == nil:
      entry.tInfo = tinfo
    else:
      let t = unify(tinfo, entry.tinfo)
      if t.isBottom():
        fatal2Type(fmt"""Attribute assignment of {nameParts.join(".")} """ &
                      "doesn't match previous type",
                      node.children[1], tinfo, entry.tinfo)
      else:
        entry.tInfo = t

    # This is now a runtime error.
    # if entry.locked:
    #   fatal("You cannot assign to the (locked) attribute " &
    #         fmt"""{nameParts.join(".")}.""",
    #         node.children[0])
    node.attrRef = entry
  of NodeVarDecl:
    if not s.secondPass:
      for symDeclNode in node.children:
        for symNameNode in symDeclNode.children:
          let
            name  = symNameNode.getTokenText()
            tinfo = symNameNode.getType()
          node.nameConflictCheck(name, s, [ucVar, ucNone])
          let entry = node.addVariable(name)
          if tinfo.unify(entry.tInfo).isBottom():
            fatal2Type(fmt"Declaration of {name} doesn't match previous " &
              "use", symNameNode, tinfo, entry.tinfo)

          if name == "result":
            fatal("Cannot declare the special variable 'result'; " &
              "If you want to declare the return type of a function, then " &
              " use func fname(args) : returnType { ... ")
  of NodeVarAssign:
    if node.children[0].kind != NodeIdentifier:
      fatal("Dot assignments for variables currently not supported.",
            node.children[0])

    node.children[1].checkNode(s)

    let
      name  = node.children[0].getTokenText()
      tinfo = node.children[1].getType()

    if not s.secondPass:
      if name == "result" and not s.funcOrigin:
        fatal("Cannot assign to special variable 'result' outside a function " &
              "definition.")

      node.nameConflictCheck(name, s, [ucVar, ucNone])
    let
      entry = node.addVariable(name)
      t     = unify(tinfo, entry.tinfo)

    if t.isBottom():
      fatal2Type(fmt"Assignment of {name} doesn't match its previous type",
                 node.children[1], tinfo, entry.tinfo)
    # Locking is now a runtime check only, so we can allow multiple
    # components to work together as long as they agree on the value
    # once locked.

  of NodeUnpack:
    node.children[^1].checkNode(s)
    let
      tup = node.children[^1]
      ti  = tup.getType()

    if ti.kind == TypeTVar and not s.secondPass:
      for i in 0 ..< node.children.len() - 1:
        s.lhsIdCheck(node.children[i].getTokenText(), node, newTypeVar(),
                     node.children[i], node.children[^1])
      return # Figure it out in the second pass.

    if ti.kind != TypeTuple:
      fatal("Trying to unpack a value that is not a tuple.", tup)
    if ti.itemTypes.len() != node.children.len() - 1:
      fatal("Trying to unpack a tuple of the wrong size.", tup)

    for i, tInfo in ti.itemTypes:
      s.lhsIdCheck(node.children[i].getTokenText(), node, tInfo,
                   node.children[i], node.children[^1])
  of NodeElse:
    pushVarScope()
    node.checkKids(s)
  of NodeConditional:
    pushVarScope()
    node.checkKids(s)
    if isBottom(node.children[0], boolType):
      fatal("If conditional must evaluate to a boolean", node.children[0])
    node.typeInfo = boolType # Unneeded.
  of NodeFor:
    if not s.secondPass:
      pushVarScope()
      let
        name       = node.children[0].getTokenText()
        entry      = node.varScope.varLookup(name, vlMask).get()

      entry.tinfo  = intType
      entry.locked = true

    for i in 1 ..< node.children.len():
      node.children[i].checkNode(s)

    if node.children[1].getType().unify(intType).isBottom() or
       node.children[2].getType().unify(intType).isBottom():
      fatal("For index ranges must be integers.")
  of NodeSimpLit:
    #if s.secondPass:
    #  return
    node.value = node.nodeToSimpLit()
  of NodeUnary:
    node.checkKids(s)
    let t = node.children[0].getType()
    case t.kind
    of TypeChar, TypeInt, TypeFloat: node.typeInfo = t
    else:
      fatal("Unary operator only works on numeric types", node)
  of NodeNot:
    node.checkKids(s)
    if node.children[0].isBottom():
      fatal("There's nothing to 'not' here", node)
    node.typeInfo = boolType
  of NodeMember:
    node.children[0].checkNode(s)
    var attrScope = node.children[0].attrScope
    for item in node.children[1 .. ^1]:
      item.attrScope = attrScope
      item.checkNode(s)
      attrScope = item.attrScope
    if node.children[^1].attrRef == nil:
      fatal("Final target of member operation is a section, not an attribute")
    node.attrRef  = node.children[^1].attrRef
    node.typeInfo = node.attrRef.tInfo
  of NodeIndex:
    node.checkKids(s)
    let ti = node.children[0].getType()
    case ti.kind
    of TypeString:
      if isBottom(node.children[1], intType):
        fatal("Invalid string index (ints only)", node.children[1])
      node.typeInfo = charType
    of TypeTuple:
      if isBottom(node.children[1], intType):
        fatal("Invalid tuple index (numbers only)", node.children[1])
      let v = node.children[1].value
      if node.children[1].getType() != intType:
        fatal("Tuple index must be an integer literal for " &
              "static type checking", node.children[1])
      node.typeInfo = newTypeVar()
      let i = unpack[int](v)
      if i < 0 or i >= ti.itemTypes.len():
        fatal("Tuple index out of bounds", node.children[1])
      node.typeInfo = ti.itemTypes[i]
    of TypeList:
      if isBottom(node.children[1], intType):
        fatal("Invalid list index (numbers only)", node.children[1])
      node.typeInfo = ti.itemType
    of TypeDict:
      let
        kt = ti.keyType
        vt = ti.valType
      case kt.kind
      of TypeString, TypeInt, TypeChar:
        node.typeInfo = vt
      else:
        fatal("Dict indicies can only be strings or ints", node.children[1])
    of TypeTVar:
      if not s.secondPass:
        # Note, we should *not* allow tuples as an option unless we
        # know the type of the tuple at the time of checking, and we
        # can statically resolve the index, otherwise we cannot tie
        # the return type to the type of the tuple field.
        node.typeInfo = newTypeVar()
        if node.children[1].getBaseType() == TypeInt:
          let
            keyType = node.typeInfo
            options = @[newListType(keyType), newDictType(intType, keyType)]
            tv      = newTypeVar(constraints = options)
          if tv.unify(node.children[0].getType()).isBottom():
            fatal("Invalid type constraint for this index operation")
        else:
          let ctrType = newDictType(node.typeInfo, newTypeVar())
          if ctrType.unify(node.children[0].getType()).isBottom():
            fatal("Index type doesn't match container key type")
    else:
      var n = node
      while n.parent.isSome():
        n = n.parent.get()
      fatal("Invalid type to index.", node)
  of NodeFuncDef:
    let
      name      = node.children[0].getTokenText()
      rootScope = node.varScope

    # The requirement for two type checking passes isn't universal...
    # it only happens when there is a forward reference.
    if not s.secondPass:
      node.nameConflictCheck(name, s, [ucNone, ucFunc])
      node.varScope = VarScope(parent: none(VarScope))

      # Set up the function call's root scope.  We're explicitly
      # removing global variables that do NOT persist across runs.
      # Also, this function will only be able to see variables
      # that are defined before we first reach this part of the parse.
      # That is, we do not allow forward declarations.
      #
      # First, add in a result variable, which can be any type.
      discard node.addVariable("result")

      # This copies over items in the root scope that have the
      # 'persists' flag set.
      for k, v in rootScope.contents:
        if v.persists:
          node.varScope.contents[k] = v

      # Now add in the function's parameters.  We will allow this
      # to replace existing items from the global scope, but want
      # to barf if a parameter name is reused.
      for n in node.children[1].children:
        n.varScope = node.varScope
        let
          varname = n.getTokenText()
          `sym?`  = n.varScope.varLookup(varname, vlFormal)

        if `sym?`.isNone():
          fatal(fmt"In func decl: Duplicate parameter name: {varname}", node)

    s.funcOrigin = true
    node.children[1].checkNode(s) # Now check any declared types
    node.children[2].checkNode(s)
    s.funcOrigin = false

    # Type check parameters, add the function w/ signature in the fn table.
    # We look them back up in the symbol table.
    # Note that, for now anyway, we are not accepting varargs functions.
    let
      tinfo = Con4mType(kind: TypeFunc, va: false)
      entry = node.varScope.varLookup("result", vlUse).get()

    # If the return variable was never set, firstDef will be nothing,
    # and this method returns void.
    if entry.firstDef.isNone():
      tinfo.retType = bottomType
    else:
      tinfo.retType = entry.tinfo

    node.typeInfo = tinfo

    for n in node.children[1].children:
      let
        varname = n.getTokenText()
        entry   = node.varUse(varname).get()

      tinfo.params.add(entry.tinfo)

    # Now, that we have type info, we want to update the function table.
    if not s.funcTable.contains(name):
      let f = FuncTableEntry(kind: FnUserDefined,
                             tinfo:       tinfo,
                             name:        name,
                             onStack:     false,
                             cannotCycle: false,
                             locked:      false,
                             impl:        some(node))
      discard s.addFuncDef(f)
      s.funcTable[name] = @[f]
      return

    var fnList = s.funcTable[name]
    var placeholderIx = -1
    for i, item in fnList:
      # Look for already installed info about functions of this name.
      # If we find one, perform any checks we need, and if we are allowed
      # to overwrite the old implementation, do so (and return).
      #
      # If we don't find a match, then we are adding a new signature
      # with a name that is already defined.
      case item.kind
      of FnBuiltIn:
        fatal(fmt"Function name conflicts with a builtin function", node)
      of FnUserDefined:
        if not isBottom(tinfo, item.tinfo):
          if item.locked:
            fatal("An implementation is already installed, and is locked " &
                  "(i.e., has been marked so that it can not be replaced)",
                  node)
          else:
            item.impl = some(node) # Write over the old implementation.
            if not s.addFuncDef(item):
              fatal(fmt"Duplicate implementation of function '{item.name}'",
                    node)
            return
        else:
          if item.tinfo == bottomType:
            placeholderIx = i

    if placeholderIx != -1:
      fnlist.del(placeholderIx)

    # If we get here, the name was already defined, and none of the existing
    # definitions match our signature.  Add ourselves in.
    let f = FuncTableEntry(kind:        FnUserDefined,
                           tinfo:       tinfo,
                           name:        name,
                           impl:        some(node),
                           onStack:     false,
                           cannotCycle: false,
                           locked:      false)

    fnList.add(f)
    if not s.addFuncDef(f):
      fatal(fmt"Duplicate implementation of function '{f.name}'", node)
    s.funcTable[name] = fnList

  of NodeCall:
    # Because we accept function calls for functions that aren't defined
    # yet in the source when the call appaears, we need to insert a dummy
    # type variable here, just in case we cannot resolve the type yet. This
    # will keep typechecking above this node from failing due to no info
    # about this node.

    if not s.secondPass:
      node.typeInfo = newTypeVar()
    node.children[1].checkNode(s)

    if node.children[0].kind != NodeIdentifier:
      fatal("Data objects cannot currently have methods.", node.children[0])

    let
      fname    = node.children[0].getTokenText()
      procList = s.findMatchingProcs(fname, node.children[1].getType())
    case len(proclist)
    of 1:
      discard proclist[0].tInfo.copyType().unify(node.children[1].getType())
      node.typeInfo = node.children[1].getType().retType
      node.procRef = proclist[0]
      assert proclist[0] != nil
    of 0:
      if s.secondPass:
        if fname == "echo": # Echo knows to cast each argument to a string.
          let t = toCon4mType("func(string)")
          node.procRef  = s.findMatchingProcs("echo", t)[0]
          node.typeInfo = bottomType
          return
        # Don't bail for missing f()'s if we're not executing, since we may
        # not have them if the runtime environment adds their own functions.
        var msg = fmt"No function with the name '{fname}' was found."

        if fname in s.funcTable:
          msg = "Could not find an implementation for the function " &
          fmt"'{fname}{$(node.children[1].typeInfo)}'" &
          "\nPerhaps you meant:\n"
          for item in s.funcTable[fname]:
             msg &= $(item) & "\n"
        node.children[1].typeInfo.retType = node.typeInfo
        fatal(msg)
      else:
        s.waitingForTypeInfo = true
        node.typeInfo = newTypeVar().unify(node.children[1].getType().retType)
    else:
      if not s.secondPass:
        node.typeInfo = newTypeVar().unify(node.children[1].getType().retType)
        s.waitingForTypeInfo = true
      else:
        var err = "Ambiguous call (matched multiple implementations):\n"
        for call in procList:
          err &= "  " & call.name & `$`(call.tinfo) & "\n"
        if s.funcOrigin:
          err &= "This is most likely because a parameter to your function "
          err &= "could be different types depending on the calling context. "
          err &= "While that's okay in general, function call dispatch "
          err &= "currently needs to be selected before execution begins.\n"
        err &= "Try declaring a concrete type for any variables that are " &
               "ambiguous."
        fatal(err, node.children[1])

  of NodeActuals:
    var t: seq[Con4mType]
    node.checkKids(s)

    for item in node.children:
      t.add(item.getType())

    node.typeInfo = newProcType(t, newTypeVar())
  of NodeDictLit:
    node.checkKids(s)
    var ct = newTypeVar()
    for item in node.children:
      ct = unify(ct, item.getType())
      if ct.isBottom():
        fatal("Dict items must all be the same type.", node)
    node.typeInfo = ct

    if node.isConstLit():
      var dict = newCon4mDict[Box, Box]()

      for pair in node.children:
        let
          boxedKey = pair.children[0].value
          boxedVal = pair.children[1].value
        dict[boxedKey] = boxedVal
      node.value   = pack(dict)
  of NodeKVPair:
    node.checkKids(s)
    if node.children[0].isBottom() or node.children[1].isBottom():
      fatal("Invalid type for dictionary keypair", node)
    node.typeInfo = newDictType(node.children[0].getType(),
                                node.children[1].getType())
  of NodeListLit:
    node.checkKids(s)
    var ct = newTypeVar()
    for item in node.children:
      ct = unify(ct, item.getType())
      if ct.isBottom():
        fatal("List items must all be the same type", node)
    node.typeInfo = newListType(ct)

    if node.isConstLit():
      var l: seq[Box]
      for item in node.children:
        l.add(item.value)
      node.value   = pack[seq[Box]](l)

  of NodeTupleLit:
    node.checkKids(s)
    var itemTypes: seq[Con4mType]

    for item in node.children:
      itemTypes.add(item.getType())
    node.typeInfo = Con4mType(kind: TypeTuple, itemTypes: itemTypes)

    if node.isConstLit():
      var l: seq[Box]
      for item in node.children:
        l.add(item.value)
      node.value   = pack[seq[Box]](l)

  of NodeOr, NodeAnd:
    node.checkKids(s)
    if isBottom(node.children[0], boolType) or
       isBottom(node.children[1], boolType):
      fatal("Each side of || and && expressions must eval to a bool", node)
    node.typeinfo = boolType
  of NodeNe, NodeCmp:
    node.binOpTypeCheck(@[], s,
                        "Types to comparison operators must match",
                        "== and != currently do not work on lists or dicts")
    node.typeInfo = boolType
  of NodeGte, NodeLte, NodeGt, NodeLt:
    node.binOpTypeCheck(@[intType, floatType, stringType, durationType,
                          ipAddrType, cidrType, sizeType, dateType, timeType,
                          dateTimeType, charType],
                        s,
                        "Types to comparison operators must match",
                        "Comparison ops only work on numbers and strings")
    node.typeInfo = boolType
  of NodePlus:
    node.binOpTypeCheck(@[intType, floatType, charType, stringType,
                          durationType],
                        s,
                        "Types of left and right side of binary ops must match",
                        "Invalid type for bianry operator")
  of NodeMinus:
    node.binOpTypeCheck(@[intType, floatType, charType, durationType],
                        s,
                        "Types of left and right side of binary ops must match",
                        "Invalid type for bianry operator")
  of NodeMul:
    node.binOpTypeCheck(@[intType, floatType, charType],
                        s,
                        "Types of left and right side of binary ops must match",
                        "Invalid type for bianry operator")
  of NodeMod:
    node.binOpTypeCheck(@[intType, charType],
                        s,
                        "Types of left and right side of binary ops must match",
                        "Invalid type for bianry operator")
  of NodeDiv:
    node.binOpTypeCheck(@[intType, floatType, charType],
                        s,
                        "Types of left and right side of binary ops must match",
                        "Invalid type for bianry operator")
    node.typeInfo = floatType
  of NodeCallbackLit:
    # Note that we do not bother type checking against valid functions
    # yet; this is a spec, we only type check when a callback is
    # going to be run.
    node.checkKids(s)
    if len(node.children) > 0:
      node.typeInfo = node.children[0].typeInfo.binding
    else:
      node.typeInfo = Con4mType(kind: TypeFunc, noSpec: true)

    let cbObj  = CallbackObj(name: node.getTokenText(), tInfo: node.typeInfo)
    node.value = pack(cbObj)

  of NodeIdentifier:
    # This gets used in cases where the symbol is looked up in the
    # current scope, not when it has to be in a specific scope (i.e.,
    # member access).
    let
      name          = node.getTokenText()
      `var?`        = node.varUse(name)
      `localAttr?`  = node.attrScope.attrLookup([name], 0, vlExists)
      `globalAttr?` = s.attrs.attrLookup([name], 0, vlExists)

    var typeInfo: Con4mType

    if `var?`.isSome():
      let entry    = `var?`.get()
      typeInfo     = entry.tInfo.resolveTypeVars()
      node.attrRef = nil
      if node.parent.get().kind == NodeExportDecl:
        entry.persists = true
    elif `localAttr?`.isA(AttrOrSub):
      let entry     = `localAttr?`.get(AttrOrSub)
      if entry.isA(Attribute):
        let attr     = entry.get(Attribute)
        typeInfo     = attr.tInfo.resolveTypeVars()
        node.attrRef = attr
      else:
        node.attrScope = entry.get(AttrScope)
        return
    elif `globalAttr?`.isA(AttrOrSub):
      let entry     = `globalAttr?`.get(AttrOrSub)
      if entry.isA(Attribute):
        let attr     = entry.get(Attribute)
        typeInfo     = attr.tInfo.resolveTypeVars()
        node.attrRef = attr
    elif len(node.children) == 0:
      fatal(fmt"Variable {name} used before definition", node)

    if len(node.children) != 0:
      # We do NOT recurse into the node here. The binding was set at
      # parse time, and if we descend into it, then that's going to
      # tell the NodeType object that it's a type literal.
      let
        kidType = node.children[0].getType()

      if kidType == nil:
        node.typeInfo             = typeInfo
        node.children[0].typeInfo = typeInfo
      else:
        node.typeInfo = typeInfo.unify(node.children[0].getType())
        if node.typeInfo.isBottom():
          fatal2Type("Declared type conflicts with existing type",
                     node.children[0], node.children[0].getType(), typeInfo)
    else:
      node.typeInfo = typeInfo
  of NodeType:
    ## Type nodes only get called if they're type literals (e.g., for
    ## assignment).  If they're used to annotate a variable, this does
    ## not get called.  Here, we basically cast the node into a
    ## typespec object, and set the 'value' field to the type we
    ## actually had read in.
    if not s.secondPass:
      node.typeInfo = Con4mType(kind: TypeTypeSpec, binding: node.typeInfo)
      node.value    = pack[Con4mType](node.typeInfo.binding)

  of NodeUse:
    # This pass does NOT go and retrieve the 'used' component. That happens
    # after the second pass, but before we start any evaluation.
    if not s.secondPass:
      let
        kids   = node.children
        module = kids[0].getTokenText()
        url    = if len(kids) > 1: kids[1].getTokenText() else: ""

      let component = s.getComponentReference(module, url)
      if component notin s.currentComponent.componentsUsed:
        s.currentComponent.componentsUsed.add(component)

  of NodeParamBody:
    # We don't want to call checkkids() here because the assignments
    # aren't going to be interpreted in the way they are in any other
    # part of a program.
    const
      validParamProps = ["doc", "shortdoc", "validator", "default"]
    var
      foundProps: seq[string]

    for kid in node.children:
      # Since these 'assignments' do not show up in any program scope,
      # we're leniant and accept any kind of assignment syntax so that
      # people don't have to remember.
      if kid.kind notin [NodeAttrAssign, NodeVarAssign]:
        fatal("Parameter body must only contain parameter property " &
          "assignments. Valid properties are: " & validParamProps.join(", "))
      let
        varNode  = kid.children[0]
        propname = varNode.getTokenText()

      if varnode.children.len() != 0 or propname notin validParamProps:
        fatal("Parameter properties must be one of: " &
          validParamProps.join(", "))

      if propname in foundProps:
        fatal("Dupliciate parameter property setting not allowed.")

      foundProps.add(propname)
      kid.children[1].checkNode(s)
      case propname
      of "doc", "shortdoc":
        if kid.children[1].kind != NodeSimpLit or
          kid.children[1].getTokenType() != TtStringLit:
          fatal("Parameter's doc and shortdoc properties must be string " &
            "literals")
      of "default":
        if kid.children[1].kind notin allLiteralTypes:
          fatal("Parameter's 'default' property must be a literal value " &
            "or a callback that will set the default when needed")
        if kid.children[1].kind == NodeCallbackLit:
          let allowedCallbackType = "() -> `x".toCon4mType()

          if allowedCallbackType.unify(kid.children[1].typeInfo).isBottom():
            fatal("Callback must be a function that takes no arguments and " &
              "Returns a value of the proper type.")
      of "validator":
        let allowedValidatorType = "(`x) -> string".toCon4mType()
        if kid.children[1].kind != NodeCallbackLit or
           allowedValidatorType.unify(kid.children[1].typeInfo).isBottom:
          fatal("Validator properties must point to a function taking " &
            " a single argument to validate and returning either the " &
            " empty string (on success), or an error message.")
      else:
        unreachable
  of NodeParameter:
    for item in node.children[1 .. ^1]:
      item.checkNode(s)

    var
      name: string
      attr: bool
    case node.children[0].kind
    of NodeIdentifier:
      attr = true
      name = node.children[0].getTokenText()
    of NodeVarDecl:
      attr = false
      name = node.children[0].children[0].getTokenText()
    else:
      attr = true
      var parts: seq[string]

      for item in node.children[0].children:
        parts.add item.getTokenText()

      name = parts.join(".")

    if not s.secondPass:
      # Force the second pass.  We'll validate that the types are
      # consistent in pass 2, and we'll make sure the local variables
      # exist (the attributes do not have to exist).

      s.waitingForTypeInfo = true
      var
        paramObj = ParameterInfo(name: name, defaultType: newTypeVar())
        assnNodes: seq[Con4mNode]

      if len(node.children) > 1:
        assnNodes = node.children[1].children
      for assignNode in assnNodes:
        case assignNode.children[0].getTokenText()
        of "doc":
          paramObj.doc       = some(assignNode.children[1].getTokenText())
        of "shortdoc":
          paramObj.shortdoc  = some(assignNode.children[1].getTokenText())
        of "validator":
          let fnode    = assignNode.children[1]
          let callback = unpack[CallbackObj](assignNode.children[1].value)

          if len(callback.tinfo.params) == 0:
            callback.tInfo = "(`x) -> string".toCon4mType()

          paramObj.validator = some(callback)

          if paramobj.defaultType.unify(callback.tInfo.params[0]).isBottom():
            fatal2Type("Validator parameter does not match inferred type",
                       assignNode, paramObj.defaultType, callback.tInfo)
        of "default":
          let defType = assignNode.children[1].typeInfo

          if defType.kind == TypeFunc:
            let
              callback = unpack[CallbackObj](assignNode.children[1].value)

            paramObj.defaultCb   = some(callback)
            if paramObj.defaultType.unify(defType.retType).isBottom():
              fatal2Type("Default value callback does not match inferred type",
                         assignNode, paramObj.defaultType, defType.retType)
          else:
            paramObj.default = some(assignNode.children[1].value)
            if paramObj.defaultType.unify(defType).isBottom():
              fatal2Type("Default value provided does not match inferred type",
                         assignNode, paramObj.defaultType, defType)

        else:
          unreachable
      if attr:
        s.currentComponent.attrParams[name] = paramObj
        let
          obj      = s.currentComponent.attrParams[name]
          parts    = name.split(".")
          entryOpt = node.attrScope.attrLookup(parts, 0, vlAttrDef)

        if "result" in parts:
          fatal("Cannot use special variable 'result' outside a function")

        if entryOpt.isA(AttrErr):
          fatal(entryOpt.get(AttrErr).msg, node)

        let entry = entryOpt.get(AttrOrSub).get(Attribute)

        if entry.tInfo == nil:
            entry.tInfo = obj.defaultType
        elif entry.tInfo.unify(obj.defaultType).isBottom():
          fatal2Type("Attribute parameter's inferred type does not match " &
            "the existing type for the attribute", node, obj.defaultType,
            entry.tInfo)
      else:
        let sym = node.addVariable(name)

        s.currentcomponent.varParams[name]  = paramObj
    elif attr:
      let obj = s.currentComponent.attrParams[name]

      if obj.defaultCb.isSome():
        s.ensureCallbackImplementationExists(obj.defaultCb.get())
    else:
      if name == "result":
        fatal("Cannot use special variable 'result' outside a function")

      let
        obj       = s.currentComponent.varParams[name]
        sym       = node.varUse(name).get()

      if sym.defs.len() + sym.uses.len() == 1:
        fatal("Variable parameter '" & name & "' is not defined in the " &
          "top-level component scope.")

      if sym.tInfo.unify(obj.defaultType).isBottom():
          fatal2Type("Variable parameter's default value does not " &
            "match its type as used in the module", node, obj.defaultType,
            sym.tInfo)

      if obj.defaultCb.isSome():
        s.ensureCallbackImplementationExists(obj.defaultCb.get())
  else:
    # Many nodes need no semantic checking, just ask their children,
    # if any, to check.
    node.checkKids(s)

proc checkTree*(node: Con4mNode, s: ConfigState) {.exportc, cdecl.} =
  ## Checks a parse tree rooted at `node` for static errors (i.e.,
  ## anything we can easily find before execution).  This version
  ## accepts a `ConfigState` object, so that you can keep an
  ## old symbol table around, layering new choices on top of the old
  ## ones.
  ##
  ## It does need to create a new variable scope though!
  node.attrScope = s.attrs
  node.varScope  = VarScope(parent: none(VarScope))

  # Put any persistant variable we already know about into the root
  # scope.
  for varName, sym in s.keptGlobals:
    node.varScope.contents[varName] = sym

  s.funcOrigin      = false
  s.moduleFuncDefs  = @[]
  s.moduleFuncImpls = @[]

  for item in node.children:
    item.checkNode(s)

  # Stash anything that survives stacks.
  for varName, sym in node.varScope.contents:
    if sym.persists:
      s.keptGlobals[varName] = sym
      if len(s.frames) > 0 and varName in s.frames[0]:
        sym.value = s.frames[0][varName]

  # Now that we've finished the first pass, unlink any nodes that are
  # function decls, so they don't participate in the primary program
  # execution.
  #
  var n = node.children.len()
  while n != 0:
    n = n - 1
    if node.children[n].kind == NodeFuncDef:
      node.children[n].parent = none(Con4mNode)
      s.moduleFuncImpls.add(node.children[n])
      node.children.delete(n)

  # When s.waitingForTypeInfo is set, at least one of the
  # call-before-def situations was to a function where we didn't
  # have the type, and if it got provided, we would now have the
  # type. As a result, we have to make a second typecheck pass.
  #
  # Note that we've de-rooted any functions by this point, so to be
  # able to re-check them, we kept them around.
  #
  # The secondPass flag tells the checker to skip anything not type
  # related.
  if s.waitingForTypeInfo:
    s.waitingForTypeInfo = false
    s.secondPass         = true
    for item in node.children:
      item.checkNode(s)
    for funcRoot in s.moduleFuncImpls:
      funcRoot.checkNode(s)

  # After the second pass, if any of those functions have 'result'
  # variables that were never used, then set the result variable's
  # type to ⊥ (the null type).
  for funcRoot in s.moduleFuncImpls:
    let resultVarSym = funcRoot.varScope.varLookup("result", vlUse).get()
    if len(resultVarSym.uses) == 0:
      discard resultVarSym.tInfo.unify(bottomType)

  when defined(disallowRecursion):
    # This cycle check waits until we are sure all forward references
    # are resolved.
    s.cycleCheck()
  ctrace(fmt"{getCurrentFileName()}: type checking completed.")

proc parseConstLiteral*(s: string, t: Con4mType): Box =
  if not t.unify(stringType).isBottom():
    return pack(s)

  try:
    let tree = s.parseLiteral()

    tree.checkNode(ConfigState())
    if tree.isConstLit() and not tree.typeInfo.unify(t).isBottom():
      if t == floatType and tree.value.kind == MkInt:
        return pack(float(unpack[int](tree.value)))
      else:
        return tree.value
    elif tree.typeInfo == intType and t == floatType:
      return pack(float(unpack[int](tree.value)))
  except:
    discard

  raise newException(ValueError, "Not a valid Con4m constant of type " & $t)
