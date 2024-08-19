import tables, options, streams, strutils, sequtils, sugar, os, json, types,
       errmsg, parse, eval, spec, builtins, dollars, getopts, c42spec, st,
       typecheck, run, codegen, nimutils, components

const getOptsSpec = staticRead("c4m/getopts.c42spec")

type
  ActionKind* = enum
    akInitState, akCallback, akSpecLoad, akConfLoad, akValidate,
    akStartGetOpts, akFinalizeGetOpts, akCodeGen, akSetErrHandler

  StackCallback*     = (ConfigState) -> void
  ErrorCallback*     = (string, string) -> bool
  StackRunTimeScope* = enum srsConfig, srsValidation, srsBoth
  CheckLevel*        = enum
    # CheckNone adds default values in.
    checkNone, checkAll, checkPre, checkPost, notEvenDefaults
  ConfigStep*        = ref object
    stageName*: string
    case kind*: ActionKind
    of akInitState:
      addBuiltins*: bool
      customFuncs*: seq[Con4mCustomBuiltinInfo]
      exclusions*:  seq[string]
      stubs*:       seq[string]
      which*:       StackRuntimeScope
    of akCallback:
      callback*:    StackCallback
    of akSpecLoad, akConfLoad, akValidate:
      url*:            string
      stream*:         Stream
      genSpec*:        bool
      run*:            bool
      checkLevel*:     CheckLevel
      showToks*:       bool
      showParsed*:     bool
      showTyped*:      bool
      showFuncs*:      bool
      showEarlyFns*:   bool
      showPretty*:     bool
      showJSon*:       bool
      endPhase*:       string
    of akStartGetOpts, akFinalizeGetOpts:
      args*:           seq[string]
      resPath*:        string
      printAutoHelp*:  bool
    of akCodeGen:
      language*:       string
      outFile*:        string
    of akSetErrHandler:
      handler*:        ErrorCallback

  ConfigStack* = ref object
    steps*:               seq[ConfigStep]
    ix*:                  int
    specValidationState*: ConfigState
    validationState*:     ConfigState
    configState*:         ConfigState
    lastUsed*:            ConfigState
    c42SpecObj*:          ConfigSpec
    errorCb*:             ErrorCallback
    errored*:             bool
    getOptOptions*:       seq[ArgResult]
    finalOpt*:            ArgResult
    bt*:                  bool
    getoptStarted*:       bool

proc clearError*(s: ConfigStack) =
  s.errored = false
proc getRuntime*(s: ConfigStack): ConfigState = s.configState

proc newConfigStack*(): ConfigStack = ConfigStack()
proc addSystemBuiltins*(stack:      ConfigStack,
                        exclusions: openarray[string] = @[],
                        which = srsBoth): ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akInitState, addBuiltins: true, which: which,
                        exclusions: exclusions.toSeq())
  stack.steps.add(step)

proc addCustomBuiltins*(stack: ConfigStack,
                        fns:   openarray[Con4mCustomBuiltinInfo],
                        which = srsBoth):  ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akInitState, customFuncs: fns.toSeq(),
                        which: which)

  stack.steps.add(step)

proc addStubs*(stack: ConfigStack, stubs: seq[string], which = srsBoth):
               ConfigStack {.discardable.} =
  result = stack
  var step = ConfigStep(kind: akInitState, stubs: stubs, which: which)

proc addCallback*(stack:     ConfigStack,
                  callback:  StackCallback,
                  stageName: string = ""): ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akCallback, callback: callback,
                        stageName: stageName)

  stack.steps.add(step)

proc setErrorHandler*(stack: ConfigStack, cb: ErrorCallback):
                    ConfigStack {.discardable.} =
  result    = stack
  var step = ConfigStep(kind: akSetErrHandler, handler: cb)
  stack.steps.add(step)

proc addSpecLoad*(stack:        ConfigStack,
                  url:          string,
                  stream:       Stream = nil,
                  checkLevel:   CheckLevel = checkAll,
                  genSpec:      bool = true,
                  stageName:    string = url):
                    ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akSpecLoad, url: url, run: true,
                        checkLevel: checkLevel, stageName: stageName,
                        stream: stream, genSpec: genSpec)

  stack.steps.add(step)

proc addGetoptSpecLoad*(stack:     ConfigStack,
                        stageName: string = "getopts-specload"):
                          ConfigStack {.discardable.} =
  result = stack
  var step = ConfigStep(kind: akSpecLoad, url: "getopts-spec",
                        run: true, checkLevel: checkNone,
                        stageName: stageName, genSpec: true,
                        stream: newStringStream(getOptsSpec))
  stack.steps.add(step)

proc addConfLoad*(stack:        ConfigStack,
                  url:          string,
                  stream:       Stream = nil,
                  checkLevel:   CheckLevel = checkAll,
                  stageName:    string = url):
                    ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akConfLoad, url: url, run: true,
                        checkLevel: checkLevel, stageName: stageName,
                        stream: stream)
  stack.steps.add(step)

proc addValiate*(stack:       ConfigStack,
                 stageName:   string = ""):
                   ConfigStack {.discardable.} =
  result   = stack
  var step = ConfigStep(kind: akValidate, checkLevel: checkAll, run: false)

  stack.steps.add(step)

proc addStartGetOpts*(stack:         ConfigStack,
                      resPath:       string = "getopts",
                      stageName:     string = "start-getopts",
                      printAutoHelp: bool = true,  # vs returning it.
                      args:          seq[string] = @[]):
                        ConfigStack {.discardable.} =
  result   = stack

  var argv = if len(args) > 0: args else: commandLineParams()
  var step = ConfigStep(kind: akStartGetOpts, args: argv, stageName: stageName,
                        resPath: resPath, printAutoHelp: printAutoHelp)
  stack.getoptStarted = true
  stack.steps.add(step)

proc addFinalizeGetOpts*(stack:         ConfigStack,
                         resPath:       string = "getopts",
                         stageName:     string = "finalize-getopts",
                         printAutoHelp: bool   = true):
                           ConfigStack {.discardable.} =
  if not stack.getOptStarted:
    raise newException(ValueError, "startGetOpt must have been done before " &
      "you can add a finalize step")
  result   = stack

  var step = ConfigStep(kind: akFinalizeGetOpts, stageName: stageName,
                        resPath: resPath, printAutoHelp: printAutoHelp)
  stack.steps.add(step)

proc addCodeGen*(stack:      ConfigStack,
                 language:   string,
                 outputFile: string,
                 stageName:  string = "codegen"): ConfigStack {.discardable.} =
    result = stack
    var step = ConfigStep(kind: akCodeGen, stageName: stageName,
                          language: language, outFile: outputFile)

    stack.steps.add(step)

proc createEmptyRuntime(): ConfigState =
   result = ConfigState(attrs:
                AttrScope(parent: none(AttrScope), name: "<<root>>"))
   result.attrs.config = result

template initializeSpec(specRuntime: ConfigState) =
  specRuntime.spec = some(buildC42Spec())

proc runOneConf(stack: ConfigStack, conf, spec: ConfigState) =
  let
    step      = stack.steps[stack.ix]
    component = conf.getComponentReference(step.url)

  try:
    if step.run:
      if step.stream != nil:
        component.cacheComponent(step.stream)
      else:
        component.fetchComponent()

      # TODO: this should all get redone to handle Showing the same
      # things for any sub-components.
      # if step.showToks:
      #   for i, token in tokens:
      #     stderr.writeLine($i & ": " & $token)

      # if step.showParsed:
      #   stderr.writeLine($tree)

      # if step.showEarlyFns:
      #   stderr.writeLine($(conf.funcTable))

      if step.endPhase in ["parse", "tokenize"]:
        return

      conf.secondPass = false
      conf.loadComponent(component)

      # if step.showTyped:
      #   stderr.write("# EntryPoint:".stylize())
      #   stderr.writeLine($(component.entrypoint))
      #   for item in conf.moduleFuncDefs:
      #     let typeStr = `$`(item.tInfo)
      #     stderr.write(("# Function: " & item.name & typeStr).stylize())
      #     stderr.writeLine($item.impl.get())

      # if step.showFuncs:
      #   stderr.writeLine($(conf.funcTable))

    if step.endPhase == "precheck":
      return

    if step.run: # Set up the runtime stack.
      ctrace(step.url & ": Beginning evaluation.")
      conf.evalComponent(component)
      ctrace(step.url & ": Evaluation done.")
  finally:
    if step.run:
      conf.numExecutions += 1

      # Clean up the runtime stack and stash exported global state.
      if conf.frames.len() > 0:
        for k, v in conf.frames[0]:
          if k in conf.keptGlobals:
            conf.keptGlobals[k].value = v
        conf.frames = @[]

  if step.endPhase == "eval":
    if step.checkLevel != notEvenDefaults and spec != nil:
      conf.setDefaults(spec)
    return

  if spec != nil:
    if step.checkLevel in [checkAll, checkPost]:
      conf.basicSanityCheck(spec)
      conf.validateState(spec)
    elif step.checkLevel != notEvenDefaults:
      conf.setDefaults(spec)

  if step.showPretty:
    echo conf.attrs

  if step.showJson:
    print(h1("Results") +
          code(pre(parseJson(conf.attrs.scopeToJson()).pretty())))


proc oneInit(s: ConfigState, step: ConfigStep) =
  if step.addBuiltins:
    for item in defaultBuiltins:
      let
        (sig, impl, doc, tags) = item
        ix          = sig.find('(')
        name        = sig[0 ..< ix].strip()
        tInfo       = sig[ix .. ^1].toCon4mType()

      if s.funcTable.contains(name):
        for existing in s.funcTable[name]:
          # Check to see if it's already loaded.
          if not isBottom(copyType(tInfo), copyType(existing.tInfo)): continue

      s.newCoreFunc(sig, impl, doc, tags)

  for item in step.customFuncs:
    let (sig, impl, doc, tags) = item
    s.newCoreFunc(sig, impl, doc, tags)

  for item in step.stubs:
    s.newCoreFunc(item, nil, "Stub only.", @[], true)

  for sig in step.exclusions:
    let
      ix    = sig.find('(')
      name  = sig[0 ..< ix].strip()
      tInfo = sig[ix .. ^1].toCon4mType()

    if s.funcTable.contains(name):
      var canRemain: seq[FuncTableEntry] = @[]
      for item in s.funcTable[name]:
        if isBottom(copyType(tInfo), copyType(item.tInfo)):
          canRemain.add(item)
      if len(canRemain) != 0:
        s.funcTable[name] = canRemain
      else:
        s.funcTable.del(name)

proc doInit(stack: ConfigStack) =
  let step = stack.steps[stack.ix]

  if step.which != srsConfig:
    if stack.validationState == nil:
      stack.validationState = createEmptyRuntime()
    stack.validationState.oneInit(step)
    stack.lastUsed = stack.validationState

  if step.which != srsValidation:
    if stack.configState == nil:
      stack.configState = createEmptyRuntime()
      if stack.c42SpecObj != nil:
        stack.configState.spec = some(stack.c42SpecObj)
    stack.configState.oneInit(step)
    stack.lastUsed = stack.configState

proc doCallback(stack: ConfigStack) {.inline.} =
  # If it's nil, *shrug*
  stack.steps[stack.ix].callback(stack.lastUsed)

proc doSpecLoad(stack: ConfigStack) =
  let step = stack.steps[stack.ix]
  if stack.validationState == nil:
    stack.validationState = createEmptyRuntime()

  if stack.specValidationState == nil and step.checkLevel != notEvenDefaults:
    stack.specValidationState  = createEmptyRuntime()
    stack.validationState.spec = some(buildC42Spec())
  # load the file.

  stack.runOneConf(stack.validationState, stack.specValidationState)

  if step.genSpec:
    let specOpt = stack.validationState.spec
    let new     = stack.validationState.generateC42Spec(specOpt)

    stack.validationState.spec = some(new)

    stack.c42SpecObj = stack.validationState.generateC42Spec()
    if stack.configState != nil:
      stack.configState.spec = some(stack.c42SpecObj)

  stack.lastUsed  = stack.validationState

proc doConfLoad(stack: ConfigStack) =
  if stack.configState == nil:
    stack.configState = createEmptyRuntime()
    if stack.c42SpecObj != nil:
      stack.configState.spec = some(stack.c42SpecObj)
  if stack.validationState == nil:
    let step = stack.steps[stack.ix]
    step.checkLevel = notEvenDefaults
  stack.runOneConf(stack.configState, stack.validationState)
  stack.lastUsed = stack.configState

proc doValidate(stack: ConfigStack) =
  if stack.lastUsed == nil:
      raise newException(ValueError, "Can't validate before running anything")
  elif stack.lastUsed == stack.configState:
    if stack.configState.spec.isNone():
      raise newException(ValueError, "Can't validate: no spec loaded yet.")
    # If we're here, they loaded a spec obj programatically.
    # It won't be possible to use a runtime in such a case, but we might
    # need one later, and they're cheap, so just make one already.
    if stack.validationState == nil:
      stack.validationState = createEmptyRuntime()

    stack.runOneConf(stack.configState, stack.validationState)
  else:
    stack.runOneConf(stack.validationState, stack.specValidationState)

proc doStartGetOpts(stack: ConfigStack) =
  var res: seq[ArgResult]

  if stack.configState == nil:
    stack.configState = createEmptyRuntime()
  if stack.validationState == nil:
    raise newException(ValueError, "No spec to read getopts section from")
  let step = stack.steps[stack.ix]
  res = runManagedGetopt(stack.configState, step.args, step.resPath)
  if len(res) == 1:
    stack.finalOpt = res[0]
    if step.printAutoHelp and stack.finalOpt.helpToPrint != "":
      echo stack.finalOpt.helpToPrint
  else:
    stack.getOptOptions = res

proc doFinalizeGetOpts(s: ConfigStack) =
  if len(s.getOptOptions) < 2: return
  s.finalOpt      = finalizeManagedGetopt(s.configState, s.getOptOptions)
  s.getOptOptions = @[]
  if s.steps[s.ix].printAutoHelp and s.finalOpt.helpToPrint != "":
    echo s.finalOpt.helpToPrint

proc doCodeGen(s: ConfigStack) =
  if s.c42SpecObj == nil:
    raise newException(ValueError, "No c42 spec object has been created yet.")

  let
    step  = s.steps[s.ix]
    toOut = s.validationState.generateCode(step.language)

  if step.outFile == "":
    echo toOut
  else:
    let f = newFileStream(resolvePath(step.outFile), fmWrite)
    f.write(toOut)
    f.close()

proc doSetErrorHandler(stack: ConfigStack) =
  let step = stack.steps[stack.ix]
  stack.errorCb = step.handler

proc getArgResult*(stack: ConfigStack): ArgResult =
  if stack.finalOpt == nil:
    raise newException(ValueError, "No accepted parse for command line.")
  return stack.finalOpt
proc getCommand*(stack: ConfigStack): string = stack.getArgResult().command
proc getArgs*(stack: ConfigStack, sect = none(string)): seq[string] =
  let res = stack.getArgResult()
  if sect.isNone():
    return res.args[res.command]
  else:
    let s = sect.get()
    if res.args.contains(s):
      return res.args[s]
proc getFlags*(stack: ConfigStack, sect = none(string)):
             OrderedTable[string, FlagSpec] = stack.getArgResult().flags
proc getAttrs*(stack: ConfigStack): Option[AttrScope] =
  if stack.configState == nil: return none(AttrScope)
  return some(stack.configState.attrs)
proc getHelpStr*(a: ArgResult): string = a.helpToPrint

proc loadConfOptions(stack: ConfigStack) =
  var
    show_when = getConf[seq[string]]("show_when").getOrElse(@["none"])
    spec_when = getConf[seq[string]]("spec_when").getOrElse(@["none"])
    show      = false
    first_specload = -1
    last_specload  = -1
    first_confload = -1
    last_confload  = -1

  if "none" in show_when and "none" in spec_when: return

  for i in stack.ix ..< stack.steps.len():
    case stack.steps[i].kind
    of akSpecLoad:
      last_specload = i
      if first_specload == -1: first_specload = i
    of akConfLoad:
      last_confload = i
      if first_confload == -1: first_confload = i
    else:
      continue


  for i in stack.ix ..< stack.steps.len():
    let item = stack.steps[i]

    if item.kind == akConfLoad:
      if i == last_confload:
        if getConf[bool]("show_funcs").get():
          item.showFuncs    = true
        if getConf[bool]("show_untyped_funcs").get():
          item.showEarlyFns = true

        let stoptime = getConf[string]("stop_when").getOrElse("postcheck")
        if stoptime != "postcheck":
          item.endPhase = stoptime

        if "all" in show_when or "last" in show_when: show = true
        elif i == first_confload and "first" in show_when: show = true
        else: show = false
      elif i == first_confload:
        if "all" in show_when or "first" in show_when: show = true
        else: show = false
      else:
        if "all" in show_when or "rest" in show_when: show = true
        else: show = false
      if not show: continue

      if getConf[bool]("show_tokens").get():        item.showToks     = true
      if getConf[bool]("show_parse_tree").get():    item.showParsed   = true
      if getConf[bool]("show_checked_tree").get():  item.showTyped    = true

    elif item.kind == akSpecLoad:
      if i == last_specload:
        if "all" in spec_when or "last" in spec_when: show = true
        elif i == first_specload and "first" in spec_when: show = true
        else: show = false
      elif i == first_specload:
        if "all" in spec_when or "first" in spec_when: show = true
        else: show = false
      else:
        if "all" in spec_when or "rest" in spec_when: show = true
        else: show = false
      if not show: continue
      if getConf[bool]("show_spec_tokens").get():       item.showToks   = true
      if getConf[bool]("show_spec_parse_tree").get():   item.showParsed = true
      if getConf[bool]("show_spec_checked_tree").get(): item.showTyped  = true

proc run*(stack: ConfigStack, backtrace = false):
        Option[ConfigState] {.discardable.} =
  result = none(ConfigState)
  if stack.errored: return
  stack.bt    = backtrace

  stack.loadConfOptions()

  while stack.ix < len(stack.steps):
    let step = stack.steps[stack.ix]
    when false:
      echo step.stageName.withColor("jazzberry")
    try:
      case step.kind
      of akInitState:       stack.doInit()
      of akCallback:        stack.doCallback()
      of akSpecLoad:        stack.doSpecLoad()
      of akConfLoad:        stack.doConfLoad()
      of akValidate:        stack.doValidate()
      of akStartGetOpts:    stack.doStartGetOpts()
      of akFinalizeGetOpts: stack.doFinalizeGetOpts()
      of akCodeGen:         stack.doCodeGen()
      of akSetErrHandler:   stack.doSetErrorHandler()
    except:
      if step.kind notin [akSpecLoad, akConfLoad, akValidate] and stack.bt:
        stderr.writeLine("Error when running stack stage: " & step.stageName)

      if stack.errorCb != nil:
        stack.errored = stack.errorCb(getCurrentExceptionMsg(),
                                      getCurrentException().getStackTrace())
      else:
        stack.errored = true
        if stack.bt:
          echo getCurrentExceptionMsg()
          echo getCurrentException().getStackTrace()
      if stack.errored:
        raise
    finally:
      stack.ix = stack.ix + 1

  if stack.configState != nil: return some(stack.configState)
