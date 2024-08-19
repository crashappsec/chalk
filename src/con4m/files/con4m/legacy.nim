## Highest-level API for executing con4m. The macros provide more
## abstraction for stuff written in Nim.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, streams, nimutils, strformat
import errmsg, types, parse, treecheck, eval, spec, builtins, dollars

proc newConfigState*(node:        Con4mNode,
                     spec:        ConfigSpec     = nil,
                     addBuiltins: bool           = true,
                     exclude:     openarray[int] = []): ConfigState =
  let attrRoot   = AttrScope(parent: none(AttrScope), name: "<<root>>")
  node.attrScope = attrRoot
  node.varScope  = VarScope(parent: none(VarScope))

  let specOpt = if spec == nil: none(ConfigSpec) else: some(spec)
  result      = ConfigState(attrs:         attrRoot,
                            spec:          specOpt,
                            numExecutions: 0)

  node.attrScope.config = result

  if addBuiltins:
    result.addDefaultBuiltins(exclude)

proc initRun*(n: Con4mNode, s: ConfigState) {.inline.} =
  var topFrame = RuntimeFrame()

  for k, sym in n.varScope.contents:
    if k notin topFrame:
      topFrame[k] = sym.value

  s.frames = @[topFrame]

proc postRun(state: ConfigState) =
  if len(state.frames) > 0:
    for k, v in state.frames[0]:
      if k in state.keptGlobals:
        state.keptGlobals[k].value = v
  state.frames  = @[]

var showChecked = false
proc setShowChecked*() = showChecked = true

proc runBase(state: ConfigState, tree: Con4mNode, evalCtx: ConfigState): bool =
  if tree == nil: return false
  state.secondPass = false
  tree.checkTree(state)
  if showChecked:
    stderr.write($color("Entry point:\n", "cyan"))
    stderr.writeLine($tree)
    for item in state.moduleFuncDefs:
      if item.kind == FnBuiltIn: unreachable
      elif item.impl.isNone(): unreachable
      else:
        let typeStr = `$`(item.tInfo)
        stderr.writeLine($color(fmt"Function: {item.name}{typeStr}", "cyan"))
        stderr.writeLine($item.impl.get())

  if state.spec.isSome():
    state.basicSanityCheck(evalCtx)

  tree.initRun(state)
  try:
    ctrace(fmt"{getCurrentFileName()}: Beginning evaluation.")
    tree.evalNode(state)
    ctrace(fmt"{getCurrentFileName()}: Evaluation done.")
  finally:
    state.postRun()

  if state.spec.isSome():
    state.validateState(evalCtx)

  state.numExecutions += 1

  return true

proc firstRun*(stream:      Stream,
               fileName:    string,
               spec:        ConfigSpec                     = nil,
               addBuiltins: bool                           = true,
               customFuncs: openarray[(string, BuiltinFn)] = [],
               exclude:     openarray[int]                 = [],
               evalCtx:     ConfigState = nil): (ConfigState, bool) =
    setCurrentFileName(fileName)
    # Parse throws an error if it doesn't succeed.
    var
      tree  = parse(stream, filename)
      state = newConfigState(tree, spec, addBuiltins, exclude)

    for (sig, fn) in customFuncs:
      state.newBuiltIn(sig, fn)

    if state.runBase(tree, evalCtx):
      return (state, true)
    else:
      return (state, false)

proc firstRun*(contents:    string,
               fileName:    string,
               spec:        ConfigSpec = nil,
               addBuiltins: bool = true,
               customFuncs: openarray[(string, BuiltinFn)] = [],
               exclude:     openarray[int] = [],
               evalCtx:     ConfigState = nil): (ConfigState, bool) =
  return firstRun(newStringStream(contents), fileName, spec, addBuiltins,
                  customFuncs, exclude, evalCtx)

proc firstRun*(fileName:    string,
               spec:        ConfigSpec = nil,
               addBuiltins: bool = true,
               customFuncs: openarray[(string, BuiltinFn)] = [],
               exclude:     openarray[int] = [],
               evalCtx:     ConfigState = nil): (ConfigState, bool) =
  return firstRun(newFileStream(fileName, fmRead), fileName, spec,
                  addBuiltins, customFuncs, exclude, evalCtx)

proc stackConfig*(s:        ConfigState,
                  stream:   Stream,
                  fileName: string,
                  evalCtx:  ConfigState = nil): bool =
  setCurrentFileName(fileName)
  return s.runBase(parse(stream, fileName), evalCtx)

proc stackConfig*(s:        ConfigState,
                  contents: string,
                  filename: string,
                  evalCtx:  ConfigState = nil): bool =
  setCurrentFileName(filename)
  return s.runBase(parse(newStringStream(contents), filename), evalCtx)

proc stackConfig*(s:        ConfigState,
                  filename: string,
                  evalCtx:  ConfigState = nil): bool =
  setCurrentFileName(filename)
  return s.runBase(parse(newFileStream(filename), filename), evalCtx)
