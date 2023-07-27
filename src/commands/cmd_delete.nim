import ../config, ../collect, ../reporting, ../plugin_api

proc runCmdDelete*(path: seq[string]) =
  initCollection()

  # See runCmdInsert for info on this.
  var toRm: seq[ChalkObj] = @[]

  for item in artifacts(path):
    if not item.isMarked():
      info(item.fullPath & ": no chalk mark to delete.")
      continue
    try:
      if "$CHALK_CONFIG" in item.extract:
        warn(item.fullPath & ": Is a configured chalk exe; run it using " &
          "'chalk load default' to remove.")
        item.opFailed = true
        toRm.add(item)
        continue
      else:
        item.myCodec.handleWrite(item, none(string))
        if not item.opFailed:
          info(item.fullPath & ": chalk mark successfully deleted")
    except:
      error(item.fullPath & ": deletion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      item.opFailed = true

  doReporting()
