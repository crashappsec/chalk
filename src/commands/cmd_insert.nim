import ../config, ../collect, ../reporting, ../chalkjson, ../plugin_api


proc runCmdInsert*(path: seq[string]) =
  initCollection()
  let virtual = chalkConfig.getVirtualChalk()

  for item in artifacts(path):
    trace(item.fullPath & ": begin chalking")
    item.collectChalkInfo()
    trace(item.fullPath & ": chalk data collection finished.")
    if item.isMarked() and "$CHALK_CONFIG" in item.extract:
      info(item.fullPath & ": Is a configured chalk exe; skipping insertion.")
      item.removeFromAllChalks()
      item.forceIgnore = true
      continue
    if item.opFailed:
      continue
    try:
      let toWrite = item.getChalkMarkAsStr()
      if virtual:
        publish("virtual", toWrite)
        info(item.fullPath & ": virtual chalk created.")
      else:
        item.myCodec.handleWrite(item, some(toWrite))
        if not item.opFailed:
          info(item.fullPath & ": chalk mark successfully added")

    except:
      error(item.fullPath & ": insertion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      item.opFailed = true

  doReporting()
