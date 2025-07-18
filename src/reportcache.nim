##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This module implements report caching in the face of sink failures.
##
## If a sink fails, we stick an entry in the report cache, which is
## itself a jsonl file.  The objects in the report cache have three
## fields, one is "$sinks", which is a list of the 'sink-config' names
## for any failed sinks.  The second is "$message", the value of which
## is the JSON report, but put into a JSON string object.  Finally is
## "$topic", which captures the original topic.
##
## Generally, this will just be "report", but custom reports do get
## their own topics, and this cache covers custom reports as well.
##
## When we publish, we must first check the cache.  If there is
## anything left in the cache, then we figure out whether any of the
## 'current' sinks need to catch up.  If so, we UNSUBSCRIBE them from
## the current topic, and re-subscribe them to a topic just for them.

import "."/[
  sinks,
  types,
  utils/exec,
  utils/files,
  utils/json,
]

# These string constants are only used if there's a catastrophic
# problem w/ the reporting cache; see `panicPublish` below.
const
  msgTmpExists = """The chalk cache for undelivered chalk reports was updated, but could not be moved to its final destination.
"""
  msgCouldntRm = """The original chalk cache exists and couldn't be replaced. If this is not rectified before the next Chalk run, it can lead to inconsistencies-- things in the current file can be double-reported.  And, any new entries could be lost.

 Please move the current temporary file to the cache location, removing the old cache file.
"""
  msgCouldntMv = """Chalk had message delivery issues, and could not save its 'reporting cache' to its configured location.  This will prevent successful reporting of this data in subsequent chalk runs, unless rectified.

Please move the current temporary file to the configured cache location.
"""
  msgTmpLoc = "Temporary file location: "
  msgDstLoc = "Configured cache location: "
  msgNoTmp1 = """
Temporary file couldn't be written for undelivered chalk reports. Please copy the below contents to the correct report cache location for the next run of Chalk, or take whatever action needed to get this reporting information to its final destination.
"""
  msgNoTmp2 = "Report Cache contents:\n\n"

  msgPossibleLoss = """
New items added to the report cache, but opening the report cache failed with a permissions error. This may indicate data loss.  Please look for files of the pattern: chalk-report-cache*.jsonl, which generally should live somewhere under wherever you allow temp directories.  To be safe, you can run:

find / -name "chalk-report-cache*.jsonl" 2>/dev/null

(The 2>/dev/null avoids spurious errors due to permissions issues)

"""

type ReportCacheInfo = TableRef[string, seq[string]]

var
  reportCache: Table[string, ReportCacheInfo]
  cacheOpenFailed = false
  dirtyCache = false # Controls whether the cache will WRITE.


template doPanicWrite(s: string) =
  try:
    # TODO: This is Posix specific. Someday should make Chalk work on Windows.
    let f = newFileStream("/dev/tty", fmWrite)
    if f != nil:
      try:
        f.write(s)
      finally:
        f.close()
  except:
    try:
      stderr.write(s)
    except:
      try:
        echo(s)
      except:
        quitChalk(100)
      # If this doesn't work, we just have to give up :(

const quietTopics = ["chalk_usage_stats"]

template tracePublish(topic, m: string, prevSuccesses = false) =
  # This is the place where, if the report cache isn't being hit, we
  # wrap the JSON object we originally called "safePublish" on in a
  # JSON array.
  var
    msg = m.strip()

  msg = "[ " & msg & " ]\n"

  let startSubscriptions = allTopics[topic].getNumSubscribers()

  # Individual sinks got pulled out by the report cache logic to
  # publish seprately.  So when the condition below is true,
  # there's nothing to do, but we don't want to force the parent to
  # return

  if startSubscriptions == 0 and prevSuccesses:
    discard
  else:
    let n = publish(topic, msg)

    if topic in quietTopics:
      # Here we DO Will not get added to the report cache.
      return

    trace("Published the report for topic '" & topic & "' (" & $n &
      " subscribers)")

    if n == 0 and startSubscriptions != 0:
      if attrGet[bool]("use_report_cache"):
        error("For topic '" & topic & "': No output config is working, but " &
              "failures will be stored in the report cache")
      else:
        error("For topic '" & topic & "': ")
        error("No output configuration is working for this report, and there " &
          "is no report cache configured, so no metadata was recorded.")

        if attrGet[bool]("force_output_on_reporting_fails"):
          error("Here is the orphaned report:")
          doPanicWrite(msg)
          error("Run with --use-report-cache to automatically buffer failures " &
                "between chalk runs")
        else:
          error("Re-run with --force-output to try again, getting a report " &
            "on the console if io config fails again.")
    elif n != startSubscriptions:
      if attrGet[bool]("use_report_cache"):
        error("For topic '" & topic & "': publish failures will be cached.")
      else:
        error("No report cache is enabled; sink configs with failures will " &
              "not receive this report")
    elif n == 0:
      info("Nothing subscribed to topic: " & topic)

proc loadReportCache(fname: string) =
  once:
    try:
      let
        retries = attrGet[int]("report_cache_lock_timeout_sec")
        lines   = readViaLockFile(fname).strip().split("\n")
      for line in lines:
        let
          parse = parseJson(line.strip())
          sinks = parse["$sinks"].getElems()
          topic = parse["$topic"].getStr()
          msg   = parse["$message"].getStr()

        for item in sinks:
          let sinkName = item.getStr()

          if sinkName notin reportCache:
            let starter = {topic: @[msg]}.newTable()
            reportCache[sinkName] = ReportCacheInfo(starter)
          else:
            let cacheObj = reportCache[sinkName]
            if topic in cacheObj:
              cacheObj[topic].add(msg)
            else:
              cacheObj[topic] = @[msg]
    except ValueError:
      trace(fname & ": file lock obtained, but no report cache to read.")
    except:
      error("When opening chalk report cache for read: " &
            getCurrentExceptionMsg())
      cacheOpenFailed = true
      dumpExOnDebug()

proc serializeReportCache(numEntries: var int): string =
  # When we write the cache out, we don't want to duplicate messages,
  # and we don't want to implement refereneces... people should be
  # able to injest the cache as a jsonl file directly.  So instead of
  # storing indexed on sink configs, we store one row per message / topic
  # combo (different topics generally should be getting different
  # messages).
  #
  # In the cache, then, the ReportCacheInfo maps topics to messages.
  # Here,
  var msgMap: Table[string, (string, seq[string])]

  for sinkname, cachedInfo in reportCache:
    for topic, msgs in cachedInfo:
      for msg in msgs:
        if msg notin msgMap:
          msgMap[msg] = (topic, @[sinkname])
        else:
          var (t, s) = msgMap[msg]
          s.add(sinkname)
          msgMap[msg] = (t, s)

  for k, v in msgMap:
    let (t, s) = v
    result &= ("""{ "$message" : """ & $(%k) & """, "$topic" : """ & $(%t) &
                """, "$sinks" : """ & $( %* s) & " }\n")
    numEntries += s.len() # One 'failed' message for each sink, for each entry.

proc addSinkErrorsToCache(topic, msg: string) =
  # This is only called when there ARE sink errors, so we will need to flush
  # at the end of reporting if we get here at all.
  dirtyCache = true

  # First, we need to convert sink objects back to names, since
  # they're not stored in the object right now.
  var badSinks: seq[string]

  for name, obj in getSinkConfigs():
    if obj in sinkErrors:
      badSinks.add(name)

  # Now, we can reset sinkErrors.
  sinkErrors = @[]

  for sinkName in badSinks:
    if sinkName notin reportCache:
      reportCache[sinkName] = ReportCacheInfo({topic: @[msg]}.newTable())
    else:
      let cacheObj = reportCache[sinkName]
      if topic in cacheObj:
        cacheObj[topic].add(msg)
      else:
        cacheObj[topic] = @[msg]

proc handleCacheFlushing(topic, msg: string): bool =
  # For any sinkconfig where we need to tack on old reports, we
  # suppress its output on the given topic (by, at the end of this
  # function, unsubscringing it), and subscribe it to a tmp topic,
  # with just the one subscriber.  If publish returns 1, it means the
  # publishing succeeded this time.
  #
  # If publishing does succeed, we must remove the appropriate sink
  # configuration related entries from the cache.  Note that this may
  # not involve deleting everything-- if the same sink config has been
  # used for multiple topics (and both have failed), then we will only
  # want to remove items associated with the topic we're currently
  # handling.

  result = false

  # allTopics is defined in nimutils.  TODO: add a getAllTopics() to nimutils
  if topic notin allTopics:
    # Topic wasn't registered. Generally shouldn't be possible w/o a
    # programmer error, but we'll print a trace() message to help
    # detect such errors.
    trace("Attempted to flush cache for a non-existant topic: " & topic)
    return

  var unsubs: seq[(string, SinkConfig)]

  for subscriber in allTopics[topic].getSubscribers():
    if subscriber.name notin reportCache:
      continue
    if topic notin reportCache[subscriber.name]:
      continue

    # Once we're here, the current sink has data to try to flush, so
    # we follow the above plan.
    let tmpTopicObj = registerTopic("$tmp$" & topic & "$" & subscriber.name)
    subscribe(tmpTopicObj, subscriber)
    unsubs.add((topic, subscriber))

    let msgs = @[msg.strip()] & reportCache[subscriber.name][topic]

    # Each string is well-formed JSON already.  We combine them in an array.
    if publish(tmpTopicObj, "[ " & msgs.join(", ") & " ]") >= 1:
      # Re-publishing was successful!  Remove the entry from the cache.
      reportCache[subscriber.name].del(topic)
      dirtyCache = true
      result = true

      # Note that, just because we couldn't clear this cache entry doesn't
      # mean we need to write out any changes at the end; the reporting
      # configuration may have changed, orphaning this config, or we could
      # be running a different command that isn't using the same config
      # for publishing as the one that errored, ...
      if len(reportCache[subscriber.name]) == 0:
        reportCache.del(subscriber.name)

    # else, we do nothing; the failure will lead to the entry being added
    # when addSinkErrorsToCache() is called at the end of the full
    # call to safePublish()

  # Unsubscribes actually wait for the end, otherwise our iterator complains.
  for (topic, subscriber) in unsubs:
    discard unsubscribe(topic, subscriber)

proc panicPublish(contents, tmpfilename, targetname, err: string) =
  # Called when we need to write out a report cache, but CANNOT.
  #
  # If tmpfilename is not "", then the tmp file got successfully written.
  # We either had problems removing the file, or moving in the new file.
  #
  # In that case, we do our best to deliver the message that the cache
  # report is in the wrong place.
  #
  # But if the tmp file didn't get written, we get even more drastic.
  #
  # Note that the error() message might not deliver based on
  # preferneces, and we're okay with that.  But the rest needs to get
  # to the user if possible.

  error("Report cache not updated: " & err)

  var s = ""
  if tmpfilename != "":
    s = msgTmpExists
    if fileExists(targetname):
      s &= msgCouldntRm
    else:
      s &= msgCouldntMv
    s &= msgTmpLoc & tmpfilename & "\n"
    s &= msgDstLoc & targetname & "\n"
  else:
    s = msgNoTmp1 & "\n" & msgDstLoc & targetname & "\n" & msgNoTmp2 & contents

  doPanicWrite(s)

proc safePublish*(topic, msg: string) =
  if not attrGet[bool]("use_report_cache"):
    tracePublish(topic, msg)
    return

  # If any other IO had failed before this publish, it might have left
  # items in the global sinkErrors field, so clear it out before we
  # publish, so that when we check it, we know that the info is
  # current (The sinkErrors symbol is from config.nim)

  var successfulPublishes = false

  sinkErrors = @[]

  let fname = resolvePath(attrGet[string]("report_cache_location"))
  loadReportCache(fname)

  if reportCache.len() != 0:
    successfulPublishes = handleCacheFlushing(topic, msg)

  # This publish is just for sinks that didn't get unsubscribed...
  tracePublish(topic, msg, successfulPublishes)

  # If sinks were unsubscribed because they had some catch-up to do, but
  # the sink is still broken, then the sink config will still live in
  # the sinkErrors field at this point.

  if len(sinkErrors) != 0:
    if len(sinkErrors) != 0:
      addSinkErrorsToCache(topic, msg)

proc writeReportCache*() =
  # This is called after all reporting is done, to handle stashing any
  # reporting data that was not successfully written.
  #
  # The reports we cache here are only ones published via safePublish().
  # Everything else we might have published was probably mainly intended
  # for the console.

  if not attrGet[bool]("use_report_cache"):
    return

  # If nothing published, the reporting cache may not have been loaded, in
  # which case there's nothing do do.
  if cacheOpenFailed and len(reportCache) != 0:
    error(msgPossibleLoss)

  let fname = resolvePath(attrGet[string]("report_cache_location"))

  if not dirtyCache and len(reportCache) != 0:
    warn("Report cache contains unreported message(s); Cached entries " &
         "only report when there is an identically named output " &
         "configuration for the current run subscribed the topic " &
         "associated with cached entries.")

  if len(reportCache) != 0:
    var
      tmpfile: File
      tmpname: string
      cacheSize: int
      newCacheContents = serializeReportCache(cacheSize)

    warn("Caching " & $(cacheSize) & " unpublished chalk reports")
    try:
      (tmpfile, tmpname) = createTempFile("chalk-report-cache", ".jsonl")
      tmpfile.write(newCacheContents)
    except:
      panicPublish(newCacheContents, "", fname, getCurrentExceptionMsg())
      dumpExOnDebug()
      return
    finally:
      try:
        tmpfile.close()
      except:
        discard

    try:
      removeFile(fname)
      moveFile(tmpname, fname)
      warn("Some reports failed to publish, and are cached in: " & fname)
      warn("Will attempt to report on cache contents next invocation.")
    except:
      panicPublish(newCacheContents, tmpname, fname, getCurrentExceptionMsg())

  else:
    try:
      if dirtyCache:
        removeFile(fname)
        info("Reporting cache was successfully flushed.")
    except:
      error(fname & ": could not remove (successfully flushed) report cache:" &
        getCurrentExceptionMsg())
      error("Please remove it manually to avoid unnecessary double reporting")
      dumpExOnDebug()
