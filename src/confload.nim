import con4m, con4m/eval, nimutils, options, os, streams, strformat, os
import config, builtins, inject

proc runCmdConfLoad*() =
  var newCon4m: string
  let
    ctxSamiConf = getConfigState()
    filename    = getArgs()[0]

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
    error("Loading embedded configurations is disabled.")
    return

  if not canSelfInject():
    error("Platform does not support self-injection.")
    return

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
      return
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      error(fmt"{filename}: could not read configuration file")
      return

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
        builtins   = getCon4mBuiltins()
        callbacks  = getCon4mCallbacks()
        samiSpec   = newStringStream(samiSchema)
        baseConfig = newStringStream(baseConfig)
        testConfig = newStringStream(newCon4m)
        tree       = parse(samiSpec, "spec")
        opt        = tree.evalTree(builtins, [], callbacks)
        cnfObj     = opt.get() # This can break if the schema doesn't load.
        baseStack  = cnfObj.stackConfig(baseConfig, "base")
        `resConf?`: Option[Con4mScope]

      cnfObj.spec = ctxSamiConf.spec
      `resConf?`     = cnfObj.stackConfig(testConfig, "load candidate")

      if `resConf?`.isNone():
        error(fmt"{filename}: invalid configuration.")
        if cnfObj.errors.len() != 0:
          for err in cnfObj.errors:
            error(err)
        return

    except:
      publish("debug", getCurrentException().getStackTrace())
      error(fmt"Could not load config file: {getCurrentExceptionMsg()}")
      return

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
    samiPtrKey.setKeyValue(none(Box))

    var xSamiConfKey = getKeySpec("X_SAMI_CONFIG").get()
    xSamiConfKey.setKeyValue(some(pack(newCon4m)))

  trace(fmt"{filename}: installing configuration.")
  doInjection()
