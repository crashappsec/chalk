import options, tables, strutils, strformat, algorithm, os
import con4m, con4m/[st, eval], nimutils, nimutils/logging
import macros except error
export logging

const versionStr  = staticexec("cat ../sami.nimble | grep ^version")
const archStr     = staticexec("uname -m")
const osStr       = staticexec("uname -o")

macro declareSamiExeVersion(): untyped =
  return parseStmt("const " & versionStr)

proc getSamiExeVersion*(): string =
  declareSamiExeVersion()
  return version

proc getBinaryOS*():     string = osStr
proc getBinaryArch*():   string = archStr
proc getSamiPlatform*(): string = osStr & " " & archStr

include configs/baseconfig    # Gives us the variable baseConfig
include configs/defaultconfig # Gives us defaultConfig
include configs/con4mconfig   # gives us the variable samiConfig, which is
                              # a con4m configuration object.
                              # this needs to happen before we include types.
include types


const
  # Some string constants used in multiple places.                       
  magicBin*      = "\xda\xdf\xed\xab\xba\xda\xbb\xed"
  magicUTF8*     = "dadfedabbadabbed"
  tmpFilePrefix* = "sami"
  tmpFileSuffix* = "-extract.json"  


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
    hookCheck(userid)
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

proc geSamiLogLevel*(): string =
  return samiConfig.logLevel

proc setSamiLogLevel*(val: string) =
  discard ctxSamiConf.setOverride("log_level", pack(val))
  setLogLevel(val)
  samiConfig.logLevel = val

proc getDryRun*(): bool =
  return samiConfig.dryRun

proc setDryRun*(val: bool) =
  discard ctxSamiConf.setOverride("dry_run", pack(val))
  samiConfig.dryRun = val

proc getPublishDefaults*(): bool = 
  return samiConfig.publishDefaults

proc setPublishDefaults*(val: bool) =
  discard ctxSamiConf.setOverride("publish_defaults", pack(val))
  samiConfig.publishDefaults = val

proc getArtifactSearchPath*(): seq[string] =
  return samiConfig.artifactSearchPath

proc setArtifactSearchPath*(val: seq[string]) =

  samiConfig.artifactSearchPath = @[]

  for item in val:
    samiConfig.artifactSearchPath.add(item.resolvePath())

  discard ctxSamiConf.setOverride("artifact_search_path", pack(val))

proc getRecursive*(): bool =
  return samiConfig.recursive

proc setRecursive*(val: bool) =
  discard ctxSamiConf.setOverride("recursive", pack(val))
  samiConfig.recursive = val

proc getAllowExternalConfig*(): bool =
  return samiConfig.allowExternalConfig

proc getAllKeys*(): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    result.add(key)

proc getKeySpec*(name: string): Option[SamiKeySection] =
  if name in samiConfig.key:
    return some(samiConfig.key[name])

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

proc getInRef*(key: SamiKeySection): bool =
  return key.inRef

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

proc getOverrides*(plugin: SamiPluginSection):
                 Option[TableRef[string, int]] =
  return plugin.overrides

proc getIgnore*(plugin: SamiPluginSection): Option[seq[string]] =
  return plugin.ignore

proc getDocString*(plugin: SamiPluginSection): Option[string] =
  return plugin.docstring

proc getCommand*(plugin: SamiPluginSection): Option[string] =
  return plugin.command

proc getCommandPlugins*(): seq[(string, string)] =
  for name, plugin in samiConfig.plugin:
    if (not plugin.command.isSome()) or (not plugin.enabled):
      continue
    result.add((name, plugin.command.get()))

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


var onceLockBuiltinKeys = false

proc lockBuiltinKeys*() =
  if onceLockBuiltinKeys:
    return
  else:
    onceLockBuiltinKeys = true
  for key in getAllKeys():
    let
      prefix = "key." & key
      stdOpt = getConfigVar(ctxSamiConf, prefix & ".standard")

    if stdOpt.isNone(): continue
    
    let
      std = stdOpt.get()
      sys = getConfigVar(ctxSamiConf, prefix & ".system").get()

    if unpack[bool](std):
      discard ctxSamiConf.lockConfigVar(prefix & ".required")
      discard ctxSamiConf.lockConfigVar(prefix & ".system")
      discard ctxSamiConf.lockConfigVar(prefix & ".type")
      discard ctxSamiConf.lockConfigVar(prefix & ".standard")
      discard ctxSamiConf.lockConfigVar(prefix & ".since")
      discard ctxSamiConf.lockConfigVar(prefix & ".output_order")

    if unpack[bool](sys):
      discard ctxSamiConf.lockConfigVar(prefix & ".value")

  # These are locks of invalid fields for specific output handlers.
  # Note that all of these lock calls could go away if con4m gets a
  # locking syntax.
  discard ctxSamiConf.lockConfigVar("output.stdout.filename")
  discard ctxSamiConf.lockConfigVar("output.stdout.command")
  discard ctxSamiConf.lockConfigVar("output.stdout.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.stdout.region")
  discard ctxSamiConf.lockConfigVar("output.stdout.userid")
  discard ctxSamiConf.lockConfigVar("output.stdout.secret")        

  discard ctxSamiConf.lockConfigVar("output.local_file.command")
  discard ctxSamiConf.lockConfigVar("output.local_file.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.local_file.region")
  discard ctxSamiConf.lockConfigVar("output.local_file.userid")
  discard ctxSamiConf.lockConfigVar("output.local_file.secret")

  discard ctxSamiConf.lockConfigVar("output.s3.filename")
  discard ctxSamiConf.lockConfigVar("output.s3.command")

  const builtinSinks = ["stdout", "stderr", "local_file",
                        "s3", "post", "custom"]

  for item in builtinSinks:
    # Really need to be able to lock entire sections.  You shouldn't be
    # able to add ANY sinks from the conf file, that wouldn't work out.
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_secret")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_userid")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_filename")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_uri")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_region")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.uses_aux")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_secret")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_userid")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_filename")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_uri")    
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_region")
    discard ctxSamiConf.lockConfigVar(fmt"sink.{item}.needs_aux")

# This should mostly move to evaluation callbacks.  They can give
# better error messages more easily.
proc doAdditionalValidation*() =
  # Actually, not validation, but get this done early.
  setShowColors(samiConfig.color)

  try:
    setLogLevel(samiConfig.logLevel)
  except:
    setLogLevel(llWarn)
    warn(fmt"Log level {samiConfig.logLevel} not recognized. " &
         "Defaulting to 'warn'")
    var entry = ctxSamiConf.st.entries["log_level"]
    entry.value = some(pack("warn"))
    ctxSamiConf.st.entries["log_level"] = entry
    samiConfig.logLevel = "warn"

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

  # Now, lock a bunch of fields.
  lockBuiltinKeys()
  

proc loadEmbeddedConfig*(selfSamiOpt: Option[SamiDict],
                         dieIfInvalid = true): bool =
  var
    confString: string
    validEmbedded: bool

  if selfSamiOpt.isNone():
    validEmbedded = false
    confString = defaultConfig
  else:
    let selfSami = selfSamiOpt.get()
  
    # We extracted a SAMI object from our own executable.  Check for an
    # X_SAMI_CONFIG key, and if there is one, run that configuration
    # file, before loading any on-disk configuration file.
    if not selfSami.contains("X_SAMI_CONFIG"):
      trace("Embedded self-SAMI does not contain a configuration.")
      confString = defaultConfig
      validEmbedded = false
    else:
      confString = unpack[string](selfSami["X_SAMI_CONFIG"])
      validEmbedded = true

  let
    confStream = newStringStream(confString)
    res = ctxSamiConf.stackConfig(confStream, "<embedded>")

  if res.isNone():
    if dieIfInvalid:
      error("Embeeded configuration is invalid. Use 'setconf' command to fix")
    else:
      validEmbedded = false
  else:
    validEmbedded = true

  if not validEmbedded: return false

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()
  trace("Loaded embedded configuration file")
  return true

proc loadUserConfigFile*(selfSami: Option[SamiDict]) =
  discard loadEmbeddedConfig(selfSami)

  if not getAllowExternalConfig():
    return
    
  var
    path = getConfigPath()
    filename = getConfigFileName() # the base file name.
    fname: string                  # configPath / baseFileName
    loaded: bool = false

  for dir in path:
    fname = dir.joinPath(filename)
    if fname.fileExists():
      break
    trace(fmt"No configuration file found in {dir}.")

  if fname != "":
    trace(fmt"Loading config file: {fname}")
    try:
      let res = ctxSamiConf.stackConfig(fname)
      if res.isNone():
        error(fmt"{fname}: invalid configuration not loaded.")

        if ctxSamiConf.errors.len() != 0:
          for err in ctxSamiConf.errors:
            error(err)

        quit()
      else:
        loaded = true
      
    except Con4mError: # config file didn't load:
      info(fmt"{fname}: config file not loaded.")
      samiDebug("\n" & getCurrentException().getStackTrace())
      samiDebug("continuing.")

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()

  if loaded:
    trace(fmt"Loaded configuration file: {fname}")
  else:
    trace("Running without a config file.")
    
## Code to set us up for self-injection.
proc quitIfCantChangeEmbeddedConfig*(selfSami: Option[SamiDict]) =
  discard loadEmbeddedConfig(selfSami, dieIfInvalid = false)
  if not getCanLoad():
    error("Loading a new embedded config is diabled.")
    quit()

var selfInjection = false

proc getSelfInjecting*(): bool =
  return selfInjection
    
proc setupSelfInjection*(filename: string) =
  var newCon4m: string
  let ctxSamiConf = getConfigState()
  
  selfInjection = true

  setArtifactSearchPath(@[resolvePath(getAppFileName())])

  # The below protection is easily thwarted, especially since SAMI is open
  # source.  So we don't try to guard against it too much.
  #
  # Particularly, we'd happily inject a SAMI into a copy of the SAMI
  # executable via just standard injection, which would allow us to
  # nuke any policy that locks loading.
  #
  # Given that it's open source, no need to try to run an arms race;
  # the feature is here more to ensure there are clear operational
  # controls.
  
  if not getCanLoad():
    error("Loading embedded configurations not supported.")
    quit()
    
  if filename == "default":
    newCon4m = defaultConfig
    if getDryRun():
      dryRun("Would install the default configuration file.")
    else:
      info("Installing the default confiuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      error(fmt"{filename}: could not open configuration file")
      quit()
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      error(fmt"{filename}: could not read configuration file")
      quit()

    info(fmt"{filename}: Validating configuration.")
    
    # Now we need to validate the config, without stacking it over our
    # existing configuration. We really want to know that the file
    # will not only be a valid con4m file, but that it will meet the
    # SAMI spec.
    #
    # The only way we can be reasonably sure it will load is by running it 
    # once, as the spec validation check requires seeing the final 
    # configuration state.
    #
    # But, since configs are code that could have conditionals, evaluating
    # isn't going to tell us whether the spec we're loading is ALWYS going to
    # meet the spec, and has the unfortunate consequence of executing any
    # side-effects that the code might have, which isn't ideal. 
    #
    # Still, that's the best we can reasonably do, so we're going to go ahead 
    # and evaluate the thing once to give ourselves the best shot of detecting 
    # any errors early.  Since con4m is fully statically type checked, that
    # does provide us a reasonable amount of confidence; the only issues we
    # might have in the field are:
    #
    # 1) Spec validation failures when different conditional branches are taken.
    # 2) Runtime errors, like index-out-of-bounds errors.
    #
    # To do this check, we first re-load the base configuration in a new
    # universe, so that our checking doesn't conflict with our current
    # configuration.
    #
    # Then, we nick the (read-only) schema spec and function table from the 
    # current configuration universe, to make sure we can properly check 
    # anything in the new configuration file.
    #
    # Finally, in that new universe, we "stack" the new config over the newly
    # loaded base configuration.  The stack operation fully checks everything, 
    # so if it doesn't error, then we know the new config file is good enough, 
    # and we should load it.
    try:
      var 
        tree       = parse(newStringStream(baseConfig), "baseconfig")
        opt        = tree.evalTree()
        testState  = opt.get()
        testStream = newStringStream(newCon4m)
        
      testState.spec      = ctxSamiConf.spec
      testState.funcTable = ctxSamiConf.funcTable
      
      if testState.stackConfig(testStream, filename).isNone():
        error(fmt"{filename}: invalid configuration.")
        if testState.errors.len() != 0:
          for err in testState.errors:
            error(err)
        quit()
    except:
      error("Could not load config file: {getExceptionMessage()}")
      quit()
      
    trace(fmt"{filename}: Configuration successfully validated.")

    dryRun("The provided configuration file would be loaded.")
      
    # Now we're going to set up the injection properly solely by
    # tinkering with the config state.
    #
    # While we will leave any injection handlers in place, we will
    # NOT use a SAMI pointer.
    #
    # These keys we are requesting are all in the base config, so
    # these lookups won't fail.
    var samiPtrKey = getKeySpec("SAMI_PTR").get()
    samiPtrKey.value = none(Box)

    var xSamiConfKey = getKeySpec("X_SAMI_CONFIG").get()
    xSamiConfKey.value = some(pack(newCon4m))
