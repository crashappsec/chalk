import ../config, ../collect, ../reporting

template oneEnvItem(key: string, f: untyped) =
  let item = chalkConfig.envConfig.`get f`()
  if item.isSome():
    dict[key] = pack[string](item.get())

proc runCmdEnv*() =
  initCollection()
  var dict = ChalkDict()

  oneEnvItem("CHALK_ID",       chalkId)
  oneEnvItem("METADATA_ID",    metadataId)
  oneEnvItem("ARTIFACT_HASH",  artifactHash)
  oneEnvItem("METADATA_HASH",  metadataHash)
  oneEnvItem("_ARTIFACT_PATH", artifactPath)

  if len(dict) != 0:
    let c = ChalkObj(extract: dict, collectedData: ChalkDict(),
                     opFailed: false, marked: true)
    c.addToAllChalks()

  doReporting()
