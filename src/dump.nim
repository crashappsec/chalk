## Implements commands for configuration dumping and loading.

import tables, options, nimutils, config

proc handleConfigDump*(selfSami: Option[SamiDict], argv: seq[string]) =
  let confValid = loadEmbeddedConfig(selfSami, dieIfInvalid = false)
  if not getCanDump():
    error("Dumping embedded config is disabled.")
    quit()
  else:
    if len(argv) > 1:
      error("configDump requires at most one parameter")
      quit()

    let toDump = if selfSami.isSome(): unpack[string](selfSami.get()["X_SAMI_CONFIG"])
                 else: defaultConfig
               
    publish("confdump", toDump)

