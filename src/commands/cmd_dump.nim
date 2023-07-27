import ../config, ../selfextract

proc runCmdConfDump*() =
  var
    toDump  = defaultConfig
    argList = getArgs()
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = if chalk != nil: chalk.extract else: nil

  if chalk != nil and extract != nil and extract.contains("$CHALK_CONFIG"):
    toDump  = unpack[string](extract["$CHALK_CONFIG"])

  publish("confdump", toDump)
