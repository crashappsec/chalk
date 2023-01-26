import options, tables, strutils, strformat, algorithm, os, json
import con4m, con4m/[st, eval], nimutils, nimutils/logging
import macros except error
export logging

proc comment(s: string): string =
  let lines = s.split("\n")
  result    = ""
  for line in lines:
    result &= "# " & line & "\n"

const
  versionStr  = staticexec("cat ../sami.nimble | grep ^version")
  commitID    = staticexec("git rev-parse HEAD")
  archStr     = staticexec("uname -m")
  osStr       = staticexec("uname -o")

  # Some string constants used in multiple places.
  magicBin*      = "\xda\xdf\xed\xab\xba\xda\xbb\xed"
  magicUTF8*     = "dadfedabbadabbed"
  tmpFilePrefix* = "sami"
  tmpFileSuffix* = "-file.tmp"
  samiSchema*    = staticRead("configs/schema.c4m")
  baseFname      = "configs/baseconfig.c4m"
  defCfgFname    = "configs/defaultconfig.c4m"
  baseConfig*    = staticRead(baseFname)
  defaultConfig* = staticRead(defCfgFname) & comment(baseConfig)


## A lot of functions in this module work around the fact that Nim
## currently SUCKS when modules need to cyclically import each
## other. They don't even let you prototype across modules the way C
## does.  So a lot of data where, it'd be better for us to go out and
## query other modules when we need it, we have those modules, on
## startup (ie, not in a function), set stuff here.  Or, if we have
## to, we will drop a callback in here.
##

# These includes will autogenerate several procs, including:
# proc initialSamiRun(baseconfig, samiCon4mBuiltins, @[])
# proc loadSamiConfig(samiConfig)
#
# Note that, b/c con4m doesn't do export markers on fields right now,
# this has to be included so we have visibility from here. When I get
# time, con4m should auto-gen most of the gettrs/settrs we need.

include configs/con4mconfig   # gives us the variable samiConfig, which is
                              # a con4m configuration object.
                              # this needs to happen before we import types.
include  types

var
  samiCon4mBuiltins: seq[(string, BuiltinFn, string)]
  ctxSamiConf:       ConfigState
  samiConfig:        SamiConfig   # Type from the con4m macro.
  con4mCallbacks:    seq[(string, string)] = @[]

# These two procs are needed externally to test new conf files when loading.
proc getCon4mBuiltins*(): seq[(string, BuiltinFn, string)] =
  return samiCon4mBuiltins

proc getCon4mCallbacks*(): seq[(string, string)] =
  return con4mCallbacks

proc registerCon4mCallback*(con4mName: string, con4mType: string) =
  con4mCallbacks.add((con4mName, con4mType))

proc setSamiCon4mBuiltIns*(fns: seq[(string, BuiltinFn, string)]) =
  samiCon4mBuiltins = fns

macro declareSamiExeVersion(): untyped =
  return parseStmt("const " & versionStr)

proc getSamiExeVersion*(): string =
  declareSamiExeVersion()
  return version

proc getSamiCommitID*(): string =
  return commitID

proc getBinaryOS*():     string = osStr
proc getBinaryArch*():   string = archStr
proc getSamiPlatform*(): string = osStr & " " & archStr

var commandName: string

proc setCommandName*(str: string) =
  commandName = str

proc getCommandName*(): string =
  return commandName

var `canSelfInject?` = true

proc setNoSelfInjection*() =
  `canSelfInject?` = false

proc canSelfInject*(): bool =
  return `canSelfInject?`

proc getSelfInjecting*(): bool =
  return commandName == "confload"

template hookCheck(fieldname: untyped) =
  let s = astToStr(fieldName)

  if sinkConfData.`needs fieldName`:
    if not sinkopts.contains(s):
      warn("Sink config '" & sinkconf & "' is missing field '" & s &
           "', which is required by sink '" & sinkname &
           "' (config not installed)")


proc checkHooks*(sinkname:     string,
                 sinkconf:     string,
                 sinkConfData: SamiSinkSection,
                 sinkopts:     StringTable) =
    hookCheck(secret)
    hookCheck(uid)
    hookCheck(filename)
    hookCheck(uri)
    hookCheck(region)
    hookCheck(headers)
    hookCheck(cacheid)
    hookCheck(aux)

template dryRun*(s: string) =
  if samiConfig.dryRun:
    publish("dry-run", s)

when not defined(release):
  template samiDebug*(s: string) =
    const
      pre  = "\e[1;35m"
      post = "\e[0m"
    let
      msg = pre & "DEBUG: " & post & s & "\n"

    publish("debug", msg)
else:
  template samiDebug*(s: string) = discard


# This should prob be auto-generated.
proc getConfigState*(): ConfigState = return ctxSamiConf

proc getConfigErrors*(): Option[seq[string]] =
  if ctxSamiConf.errors.len() != 0:
    return some(ctxSamiConf.errors)

proc getConfigPath*(): seq[string] =
  return samiConfig.configPath

proc setConfigPath*(val: seq[string]) =
  discard ctxSamiConf.setOverride("config_path", pack(val))
  samiConfig.configPath = val

proc getConfigFileName*(): string =
  return samiConfig.configFileName

proc setConfigFileName*(val: string) =
  discard ctxSamiConf.setOverride("config_filename", pack(val))
  samiConfig.configFileName = val

proc setConfigFile*(val: string) =
  let (head, tail) = val.splitPath()

  setConfigPath(@[head])
  setConfigFileName(tail)

proc getPublishUnmarked*(): bool =
  return samiConfig.publishUnmarked

proc getDefaultCommand*(): Option[string] =
  return samiConfig.defaultCommand

proc getCanDump*(): bool =
  return samiConfig.canDump

proc getCanLoad*(): bool =
  return samiConfig.canLoad

proc getColor*(): bool =
  return samiConfig.color

proc setColor*(val: bool) =
  discard ctxSamiConf.setOverride("color", pack(val))
  setShowColors(val)
  samiConfig.color = val

proc getConsoleLogLevel*(): string =
  return samiConfig.logLevel

proc setConsoleLogLevel*(val: string) =
  discard ctxSamiConf.setOverride("log_level", pack(val))
  setLogLevel(val)
  samiConfig.logLevel = val

proc getSamiLogLevel*(): string =
  return samiConfig.samiLogLevel

proc getDryRun*(): bool =
  return samiConfig.dryRun

proc setDryRun*(val: bool) =
  discard ctxSamiConf.setOverride("dry_run", pack(val))
  samiConfig.dryRun = val

proc getPublishAudit*(): bool =
   return samiConfig.publishAudit

proc getPublishDefaults*(): bool =
  return samiConfig.publishDefaults

proc setPublishDefaults*(val: bool) =
  discard ctxSamiConf.setOverride("publish_defaults", pack(val))
  samiConfig.publishDefaults = val

proc getCacheFdLimit*(): int =
  return samiConfig.cacheFdLimit

proc getArtifactSearchPath*(): seq[string] =
  return samiConfig.artifactSearchPath

proc setArtifactSearchPath*(val: seq[string]) =
  if len(val) == 0:
    return

  samiConfig.artifactSearchPath = @[]

  for item in val:
    samiConfig.artifactSearchPath.add(item.resolvePath())

  discard ctxSamiConf.setOverride("artifact_search_path", pack(val))

proc getIgnorePatterns*(): seq[string] =
  return samiConfig.ignorePatterns

proc getRecursive*(): bool =
  return samiConfig.recursive

proc setRecursive*(val: bool) =
  discard ctxSamiConf.setOverride("recursive", pack(val))
  samiConfig.recursive = val

proc getAllowExternalConfig*(): bool =
  return samiConfig.allowExternalConfig

proc getIgnoreBrokenConf*(): bool =
  return samiConfig.ignoreBrokenConf

proc getAllKeys*(): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    result.add(key)

proc getRequiredKeys*(): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    if val.required:
      result.add(key)

proc getKeySpec*(name: string): Option[SamiKeySection] =
  if name in samiConfig.key:
    return some(samiConfig.key[name])

proc setKeyValue*(sec: SamiKeySection, b: Option[Box]) =
  sec.value = b

proc getOrderedKeys*(): seq[string] =
  let keys = getAllKeys()

  var list: seq[(int, string)] = @[]

  for key in keys:
    let spec = getKeySpec(key).get()
    list.add((spec.outputOrder, key))

  list.sort()

  for (priority, key) in list:
    result.add(key)

proc getCustomKeys*(): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    if val.since.isNone():
      result.add(key)

proc getPluginConfig*(name: string): Option[SamiPluginSection] =
  if name in samiConfig.plugin:
    return some(samiConfig.plugin[name])

proc getRequired*(key: SamiKeySection): bool =
  return key.required

proc getSystem*(key: SamiKeySection): bool =
  return key.system

proc getSquash*(key: SamiKeySection): bool =
  return key.squash

proc getStandard*(key: SamiKeySection): bool =
  return key.standard

proc getMustForce*(key: SamiKeySection): bool =
  return key.mustForce

proc getSkip*(key: SamiKeySection): bool =
  return key.skip

proc getInPtr*(key: SamiKeySection): bool =
  return key.inPtr

proc getOutputOrder*(key: SamiKeySection): int =
  return key.outputOrder

proc getSince*(key: SamiKeySection): Option[string] =
  return key.since

proc getType*(key: SamiKeySection): string =
  return key.`type`

proc getValue*(key: SamiKeySection): Option[Box] =
  return key.value

proc getDocString*(key: SamiKeySection): Option[string] =
  return key.docString

proc getPriority*(plugin: SamiPluginSection): int =
  return plugin.priority

proc getCodec*(plugin: SamiPluginSection): bool =
  return plugin.codec

proc getEnabled*(plugin: SamiPluginSection): bool =
  return plugin.enabled

proc getKeys*(plugin: SamiPluginSection): seq[string] =
  return plugin.keys

proc getIgnore*(plugin: SamiPluginSection): seq[string] =
  return plugin.ignore

proc getOverrides*(plugin: SamiPluginSection): seq[string] =
  return plugin.overrides

proc getUsesFstream*(plugin: SamiPluginSection): bool =
  return plugin.usesFstream

proc getDocString*(plugin: SamiPluginSection): Option[string] =
  return plugin.docstring

proc getAllSinks*(): TableRef[string, SamiSinkSection] =
  result = samiConfig.sink

proc getSinkConfig*(hook: string): Option[SamiSinkSection] =
  if samiConfig.`sink`.contains(hook):
    return some(samiConfig.`sink`[hook])
  return none(SamiSinkSection)

proc getOutputPointers*(): bool =
  let contents = samiConfig.key["SAMI_PTR"]

  if contents.getValue().isSome() and not contents.getSkip():
    return true

  return false

var builtinKeys: seq[string] = @[]
var systemKeys:  seq[string] = @[]
var codecKeys:   seq[string] = @[]

proc isBuiltinKey*(name: string): bool =
  return name in builtinKeys

proc isSystemKey*(name: string): bool =
  return name in systemKeys

proc isCodecKey*(name: string): bool =
  return name in codecKeys

proc lockBuiltinKeys*() =
  for key in getAllKeys():
    builtinKeys.add(key)
    let
      prefix = "key." & key
      stdOpt = getConfigVar(ctxSamiConf, prefix & ".standard")

    if stdOpt.isNone(): continue

    let
      std  = stdOpt.get()
      sys  = getConfigVar(ctxSamiConf, prefix & ".system").get()
      codec = getConfigVar(ctxSamiConf, prefix & ".codec").get()

    if unpack[bool](std):
      discard ctxSamiConf.lockConfigVar(prefix & ".required")
      discard ctxSamiConf.lockConfigVar(prefix & ".system")
      discard ctxSamiConf.lockConfigVar(prefix & ".type")
      discard ctxSamiConf.lockConfigVar(prefix & ".standard")
      discard ctxSamiConf.lockConfigVar(prefix & ".since")
      discard ctxSamiConf.lockConfigVar(prefix & ".output_order")
      discard ctxSamiConf.lockConfigVar(prefix & ".codec")

    if unpack[bool](sys):
      discard ctxSamiConf.lockConfigVar(prefix & ".value")
      systemKeys.add(key)

    if unpack[bool](codec):
      codecKeys.add(key)

  discard ctxSamiConf.lockConfigVar("key._MAGIC.json.in_ptr")
  discard ctxSamiConf.lockConfigVar("key.SAMI_ID.in_ptr")
  discard ctxSamiConf.lockConfigVar("key.SAMI_VERSION.in_ptr")
  discard ctxSamiConf.lockConfigVar("key.SAMI_PTR.in_ptr")
  discard ctxSamiConf.lockConfigVar("key.METADATA_ID.in_ptr")
  # These are locks of invalid fields for specific output handlers.
  # Note that all of these lock calls could go away if con4m gets a
  # locking syntax.
  discard ctxSamiConf.lockConfigVar("output.stdout.filename")
  discard ctxSamiConf.lockConfigVar("output.stdout.command")
  discard ctxSamiConf.lockConfigVar("output.stdout.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.stdout.region")
  discard ctxSamiConf.lockConfigVar("output.stdout.uid")
  discard ctxSamiConf.lockConfigVar("output.stdout.secret")

  discard ctxSamiConf.lockConfigVar("output.local_file.command")
  discard ctxSamiConf.lockConfigVar("output.local_file.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.local_file.region")
  discard ctxSamiConf.lockConfigVar("output.local_file.uid")
  discard ctxSamiConf.lockConfigVar("output.local_file.secret")

  discard ctxSamiConf.lockConfigVar("output.s3.filename")
  discard ctxSamiConf.lockConfigVar("output.s3.command")

  for item, _ in samiConfig.sink:
    # Really need to be able to lock entire sections.  You shouldn't be
    # able to add ANY sinks from the conf file, that wouldn't work out.
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_secret")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_uid")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_filename")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_uri")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_region")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_aux")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_secret")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_uid")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_filename")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_uri")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_region")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_aux")

# Do last-minute sanity-checking so we can give better error messages
# more easily.  This function currently runs once for each config
# loading, to do any sanity checking.  Could probably do more with it.
# A lot of what's currently here should eventually move to
# auto-generated bits in the con4m spec, though.

proc doAdditionalValidation() =
  # Actually, not validation, but get this done early.
  setShowColors(samiConfig.color)

  try:
    setLogLevel(samiConfig.logLevel)
  except:
    setLogLevel(llInfo)
    warn(fmt"Log level '{samiConfig.logLevel}' not recognized. " &
         "Defaulting to 'info'")
    var entry = ctxSamiConf.st.entries["log_level"]
    entry.value = some(pack("info"))
    ctxSamiConf.st.entries["log_level"] = entry
    samiConfig.logLevel = "info"

  if samiConfig.samiLogLevel notin toLogLevelMap:
    warn(fmt"Log level for outputting to SAMIs '{samiConfig.samiLogLevel}' " &
      "is not recognized. Defaulting to 'warn'")
    samiConfig.samiLogLevel = "warn"

  # Take any paths and turn them into absolute paths.
  for i in 0 ..< len(samiConfig.artifactSearchPath):
    samiConfig.artifactSearchPath[i] =
      samiConfig.artifactSearchPath[i].resolvePath()

  for i in 0 ..< len(samiConfig.configPath):
    samiConfig.configPath[i] = samiConfig.configPath[i].resolvePath()

  # Make sure the sinks specified are all sinks we have
  # implementations for.
  for sinkname, _ in samiConfig.sink:
    if getSink(sinkname).isNone():
      warn(fmt"Config declared sink '{sinkname}', but no implementation exists")

  # Now, lock a bunch of fields.  But this is only needed once, when
  # we load the schema.
  once:
    lockBuiltinKeys()


proc loadEmbeddedConfig*(selfSamiOpt: Option[SamiDict]): bool =
  var
    confString:     string

  if selfSamiOpt.isNone():
    confString = defaultConfig
  else:
    let selfSami = selfSamiOpt.get()

    # We extracted a SAMI object from our own executable.  Check for an
    # X_SAMI_CONFIG key, and if there is one, run that configuration
    # file, before loading any on-disk configuration file.
    if not selfSami.contains("X_SAMI_CONFIG"):
      trace("Embedded self-SAMI does not contain a configuration.")
      confString = defaultConfig
    else:
      confString = unpack[string](selfSami["X_SAMI_CONFIG"])

  try:
    let
      confStream = newStringStream(confString)
      res = ctxSamiConf.stackConfig(confStream, "<embedded configuration>")
  except:
    if getCommandName() == "setconf":
      return true
    else:
      error("Embedded configuration is invalid. Use 'setconf' command to fix")
      return false

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()
  trace("Loaded embedded configuration file")

  var c4errLevel =  if samiConfig.con4mPinpoint: c4vShowLoc else: c4vBasic

  if samiConfig.con4mTraces:
    c4errLevel = if c4errLevel == c4vBasic: c4vTrace else: c4vMax

  setCon4mVerbosity(c4errLevel)

  return true

proc loadUserConfigFile*(commandName: string,
                         selfSami:    Option[SamiDict]): Option[string]  =

  var
    path     = getConfigPath()
    filename = getConfigFileName() # the base file name.
    fname:     string              # configPath / baseFileName
    loaded:    bool   = false
    contents:  string = ""

  for dir in path:
    fname = dir.joinPath(filename)
    if fname.fileExists():
      break
    trace(fmt"No configuration file found in {dir}.")

  if fname != "":
    info(fmt"Loading config file: {fname}")
    try:
      var
        fd   = newFileStream(fname)
        res  = ctxSamiConf.stackConfig(fname)
      if res.isNone():
        error(fmt"{fname}: invalid configuration not loaded.")

        if ctxSamiConf.errors.len() != 0:
          for err in ctxSamiConf.errors:
            error(err)

        return none(string)
      else:
        fd.setPosition(0)
        contents = fd.readAll()
        loaded = true

    except Con4mError: # config file didn't load:
      info(fmt"{fname}: config file not loaded.")
      if samiConfig.ignoreBrokenConf:
        return none(string)
      trace("ignore_broken_conf is false: terminating.")
      quit()

  samiConfig = ctxSamiConf.loadSamiConfig()
  let x = samiConfig.plugin["gitrepo"]
  doAdditionalValidation()

  if loaded:
    trace(fmt"Loaded configuration file: {fname}")
    return some(contents)

  else:
    trace("No user config file loaded.")
    return none(string)

proc loadBaseConfiguration*() =
  # For our internal configurations, if we mess up, we want to see
  # all the debug info.  We'll turn that off later though.
  setCon4mVerbosity(c4vMax)

  # First we load the schema.
  assert len(samiCon4mBuiltins) != 0
  let
   (x, y) = firstSamiRun(samiSchema,
                         samiCon4mBuiltins,
                         @[],
                         con4mCallbacks)
  ctxSamiConf = x
  samiConfig  = y

  if samiConfig == nil:
    for err in ctxSamiConf.errors:
      error(err)
    quit(1)

  # Now stack on the "base" configuration.
  try:
    let
      baseStream = newStringStream(baseConfig)
      fName      = "<compile_location>/src/" & baseFname
      stack      = ctxSamiConf.stackConfig(baseStream, fname)

  except:
    error("The base configuration is broken.")
    quit(1)

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()
  setCon4mVerbosity(c4vShowLoc)
