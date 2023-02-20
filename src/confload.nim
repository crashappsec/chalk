## This module implements the "confload" command, which loads a con4m
## configuration into the chalk embedded in the executable itself.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import con4m, con4m/eval, nimutils, options, os, streams, strformat, os
import config, builtins, inject

proc runCmdConfLoad*() =
  var newCon4m: string
  let filename = getArgs()[0]

  setArtifactSearchPath(@[resolvePath(getAppFileName())])

  # The below protection is easily thwarted, especially since chalk is
  # open source.  So we don't try to guard against it too much.
  #
  # Particularly, we'd happily inject halk into a copy of the chalk
  # executable via just standard injection, which would allow us to
  # nuke any policy that locks loading.
  #
  # Given that it's open source, no need to try to run an arms race;
  # the feature is here more to ensure there are clear operational
  # controls.

  if not chalkConfig.getCanLoad():
    error("Loading embedded configurations is disabled.")
    return

  if not canSelfInject():
    error("Platform does not support self-injection.")
    return

  if filename == "default":
    newCon4m = defaultConfig
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
    # chalk spec.
    #
    # We go ahead and execute it, so that it can go through full
    # validation, even though it could easily side-effect.
    #
    # To do that, we need to give it a valid base state, clear of any
    # existing configuration.  So we stash the existing config state,
    # reload the base configs, and then validate the existing spec.
    #
    # And then, of course, restore the old spec when done.

    var
      realEvalCtx = ctxChalkConf
      realConfig  = chalkConfig
    try:
      loadBaseConfiguration()
      var
        testConfig = newStringStream(newCon4m)
        tree       = parse(testConfig, filename)

      tree.checkTree(ctxChalkConf)
      ctxChalkConf.preEvalCheck(c42Ctx)
      tree.initRun(ctxChalkConf)
      tree.evalNode(ctxChalkConf)
      ctxChalkConf.validateState(c42Ctx)
      # Replace the real state.
      ctxChalkConf = realEvalCtx
      chalkConfig  = realConfig
    except:
      ctxChalkConf = realEvalCtx
      chalkConfig  = realConfig
      publish("debug", getCurrentException().getStackTrace())
      error(fmt"Could not load config file: {getCurrentExceptionMsg()}")
      return

    trace(fmt"{filename}: Configuration successfully validated.")

    dryRun("The provided configuration file would be loaded.")

    # Now we're going to set up the injection properly solely by
    # tinkering with the config state.
    #
    # While we will leave any injection handlers in place, we will
    # NOT use a chalk pointer.
    #
    # These keys we are requesting are all in the base config, so
    # these lookups won't fail.
    var chalkPtrKey = getKeySpec("CHALK_PTR").get()
    chalkPtrKey.setValue(none(Box))

    var xChalkConfKey = getKeySpec("X_CHALK_CONFIG").get()
    xChalkConfKey.setValue(some(pack(newCon4m)))

  trace(fmt"{filename}: installing configuration.")
  doInjection()
