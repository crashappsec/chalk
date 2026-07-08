##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Default sink implementations (stdout, stderr, file, rotating_log, s3, post,
## presign). Moved from nimutils so all sink implementation is self-contained in
## chalk.
##
## addDefaultSinks() must be called at module level in sinks.nim, not inside
## ioSetup()'s once: block: the hook lets in sinks.nim call
## getSinkImplementation("stderr"), which requires "stderr" to be registered
## first; and those lets must be module-level because con4mfuncs.nim subscribes
## to con4mTopic using defaultCon4mHook at import time, before ioSetup() is
## ever called.

import std/[
  streams,
  tables,
  options,
  os,
  strutils,
  net,
  uri,
  httpclient,
  tempfiles,
  parseutils,
]
import pkg/nimutils/[
  s3client,
  pubsub,
  misc,
  random,
  encodings,
  file,
  net,
]
import "."/[
  http,
]

const defaultLogSearchPath = @["/var/log/", "~/.log/", "."]

proc openLogFile*(name: string,
                  loc:  var string,
                  path: seq[string],
                  mode              = fmAppend): Option[FileStream] =
  var
    fstream:  FileStream  = nil
    fullPath: seq[string] = path
    baseName: string      = name

  if '/' in name:
    let (head, tail) = splitPath(resolvePath(name))

    baseName = tail
    fullPath = @[head] & fullPath

  for item in fullPath:
    try:
      let directory = resolvePath(item)
      createDir(directory)
      loc           = joinPath(directory, baseName)
      fstream       = newFileStream(loc, mode)
      if fstream == nil:
        continue
      break
    except:
      continue

  if fstream == nil:
    try:
      let directory = createTempDir(baseName, "tmpdir")
      loc           = joinPath(directory, baseName)
      fstream       = newFileStream(loc, mode)
    except:
      return none(FileStream)

  if mode notin [fmRead, fmAppend]:
    discard fstream.readAll()

  return some(fstream)

template cantLog() =
  var err = "Couldn't open a log file for sink configuration '" & cfg.name &
    "'; requested file was: '" & cfg.params["filename"] & "'"

  if '/' in cfg.params["filename"]:
    err &= "Fallback search path: "
  else:
    err &= "Directories tried: "

  err &= logpath.join(", ")
  raise newException(IOError, err)

proc stdoutSinkOut(msg:    string,
                   cfg:    SinkConfig,
                   t:      Topic,
                   ignore: StringTable) =
  stdout.write(msg)
  if not msg.endsWith('\n'):
    stdout.write("\n")

proc addStdoutSink*() =
  registerSink("stdout", SinkImplementation(outputFunction: stdoutSinkOut))

proc stderrSinkOut(msg:    string,
                   cfg:    SinkConfig,
                   t:      Topic,
                   ignore: StringTable) =
  stderr.write(msg)
  if not msg.endsWith('\n'):
    stderr.write("\n")

proc addStderrSink*() =
  registerSink("stderr", SinkImplementation(outputFunction: stderrSinkOut))

proc fileSinkOut*(msg: string, cfg: SinkConfig, t: Topic, ignore: StringTable) =
  var stream = FileStream(cfg.private)
  if stream == nil:
    var
      outloc:    string
      streamOpt: Option[FileStream]
      mode    = fmAppend
      logpath: seq[string]

    if "use_search_path" notin cfg.params or
      cfg.params["use_search_path"] == "true":
      if "log_search_path" in cfg.params:
        logpath = cfg.params["log_search_path"].split(':')
      else:
        logpath = defaultLogSearchPath

      if "mode" in cfg.params and cfg.params["mode"] == "w":
         mode = fmWrite

      streamOpt = openLogFile(cfg.params["filename"], outloc, logpath, mode)
      if streamOpt.isNone():
        cantLog()
      stream = streamOpt.get()
    else:
      stream = newFileStream(resolvePath(cfg.params["filename"]), mode)
      if stream == nil:
        cantLog()

    cfg.params["actual_file"] = outloc
    cfg.private               = RootRef(stream)
    cfg.iolog(t, "Open")

  stream.write(msg)
  cfg.iolog(t, "Write")

proc fileSinkClose(cfg: SinkConfig): bool =
  try:
    var stream = FileStream(cfg.private)

    if stream != nil:
      stream.close()
    return true
  except:
    return false

type LogSinkState* = ref object of RootRef
  stream*:   FileStream
  maxSize*:  uint
  truncAmt*: uint

proc rotoLogSinkInit(cfg: SinkConfig): bool =
  try:
    var
      maxSize:  uint
      truncAmt: uint

    if parseUInt(cfg.params["max"], maxSize) != len(cfg.params["max"]):
      return false
    if maxSize < 1024:
      return false
    if "truncation_amount" in cfg.params:
      if parseUInt(cfg.params["truncation_amount"], truncAmt) !=
         len(cfg.params["truncation_amount"]):
        return false
      if truncAmt >= maxSize:
        return false
    else:
        truncAmt = maxSize shr 2

    cfg.private = LogSinkState(maxSize: maxSize, truncAmt: truncAmt)
    return true
  except:
    return false

proc rotoLogSinkOut(msg: string, cfg: SinkConfig, t: Topic, tbl: StringTable) =
  var logState = LogSinkState(cfg.private)

  if logState.stream == nil:
    var
      outloc:    string
      streamOpt: Option[FileStream]
      logpath:   seq[string]

    if "log_search_path" in cfg.params:
      logpath = cfg.params["log_search_path"].split(':')
    else:
      logpath = defaultLogSearchPath

    streamOpt = openLogFile(cfg.params["filename"], outloc, logpath)

    if streamOpt.isNone():
      cantLog()

    logState.stream           = streamOpt.get()
    cfg.params["actual_file"] = outloc
    cfg.iolog(t, "Open")

  if msg[^1] != '\n':
    logState.stream.write(msg & '\n')
  else:
    logState.stream.write(msg)

  cfg.iolog(t, "Write")
  let loc = uint(logState.stream.getPosition())

  if loc > logState.maxSize and logState.maxSize > uint(len(msg) + 1):
    let
      fullPath = cfg.params["actual_file"]
      truncLen = logState.truncAmt

    logState.stream.close()

    let
      oldf            = newFileStream(fullPath, fmRead)
      (newfptr, path) = createTempFile("sink." & cfg.name, "log")
      newf            = newFileStream(newfptr)

    while oldf.getPosition() < int64(truncLen):
      discard oldf.readLine()

    while oldf.getPosition() < int64(loc):
      newf.writeLine(oldf.readLine())

    oldf.close()
    newf.close()
    moveFile(path, fullPath)
    logState.stream    = nil
    cfg.iolog(t, "Truncate")

type S3SinkState* = ref object of RootRef
  region*:   string
  uri*:      Uri
  uid*:      string
  secret*:   string
  token*:    string
  bucket*:   string
  objPath*:  string
  nameBase*: string
  extra*:    string
  endpoint*: string

proc s3SinkInit(cfg: SinkConfig): bool =
  try:
    let
      uri                 = parseUri(cfg.params["uri"])
      bucket              = uri.hostname
      uid                 = cfg.params["uid"]
      secret              = cfg.params["secret"]
      token               = cfg.params.getOrDefault("token", "")
      region              = cfg.params.getOrDefault("region", defaultRegion)
      extra               = cfg.params.getOrDefault("extra", "")
      rawPath             = uri.path
      baseObj             = if rawPath.len > 1: rawPath[1 .. ^1] else: ""
      (objPath, nameBase) = splitPath(baseObj)
      endpoint = cfg.params.getOrDefault("endpoint", "")

    cfg.private = S3SinkState(region: region, uri: uri, uid: uid,
                              secret: secret, token: token,
                              bucket: bucket, objPath: objPath,
                              nameBase: nameBase, extra: extra,
                              endpoint: endpoint)
    return true
  except:
    return false

proc s3SinkOut(msg: string, cfg: SinkConfig, t: Topic, ignored: StringTable) =
  var
    state  = S3SinkState(cfg.private)
    client = if state.endpoint != "":
               newS3Client((state.uid, state.secret, state.token),
                           state.region, state.endpoint)
             else:
               newS3Client((state.uid, state.secret, state.token),
                           state.region)

  cfg.iolog(t, "Open")

  let
      ts           = $(unixTimeInMS())
      randVal      = base32vEncode(secureRand[array[16, char]]())
  var
      objParts: seq[string] = @[ts, randVal]

  if state.extra != "": objParts.add(state.extra)

  objParts.add(state.nameBase)

  let
      newTail  = objParts.join("-")
      rawPath  = joinPath(state.objPath, newTail)
      newPath  = if rawPath.startsWith("/"): rawPath else: "/" & rawPath
      response = client.put_object(state.bucket, newPath, msg)

  cfg.iolog(t, "Post to: " & newPath & "; response = " & response.status)

proc httpHeaders(cfg: SinkConfig): HttpHeaders =
  var
    tups:        seq[(string, string)] = @[]
    contentType: string                = cfg.params["content_type"]

  if "headers" in cfg.params:
    var
      rawHeaders = cfg.params["headers"].split("\n")

    for line in rawHeaders:
      let ix  = line.find(":")
      if ix == -1:
        continue
      let
        key = line[0 ..< ix].strip()
        val = line[ix + 1 .. ^1].strip()
      tups.add((key, val))

  tups.add(("Content-Type", contentType))

  var headers = newHttpHeaders(tups)

  if cfg.auth.isSome():
    let auth = cfg.auth.get()
    headers = auth.implementation.injectHeaders(auth, headers)

  return headers

proc httpParams(cfg: SinkConfig): tuple[
  uri: Uri,
  headers: HttpHeaders,
  timeout: int,
  disallowHttp: bool,
  pinnedCert: string,
  preferBundledCerts: bool,
] =
  let
    uri          = parseUri(cfg.params["uri"])
    headers      = cfg.httpHeaders()
    disallowHttp = "disallow_http" in cfg.params
  var
    timeout            = 1000
    pinnedCert         = ""
    preferBundledCerts = false
  if "pinned_cert_file" in cfg.params:
    pinnedCert = cfg.params["pinned_cert_file"]
  elif "prefer_bundled_certs" in cfg.params:
    preferBundledCerts = cfg.params["prefer_bundled_certs"] == "true"
  elif "timeout" in cfg.params:
    let paramstr = cfg.params["timeout"]
    if parseInt(paramstr, timeout) != len(paramstr):
      raise newException(ValueError, "Timeout must be miliseconds " &
                         "represented as an integer, or 0 for no timeout.")
    elif timeout <= 0:
      timeout = -1
  return (uri, headers, timeout, disallowHttp, pinnedCert, preferBundledCerts)

proc postSinkOut(msg: string, cfg: SinkConfig, t: Topic, ignored: StringTable) =
  let
    params   = cfg.httpParams()
    headers  = params.headers.addChalkCoreHeaders(body = msg)
    response = safeRequest(
      url                = params.uri,
      timeout            = params.timeout,
      headers            = headers,
      disallowHttp       = params.disallowHttp,
      pinnedCert         = params.pinnedCert,
      preferBundledCerts = params.preferBundledCerts,
      httpMethod         = HttpPost,
      body               = msg,
      retries            = 2,
      firstRetryDelayMs  = 100,
      acceptStatusCodes  = [200..299],
    )

  cfg.iolog(t, "Post " & response.status)

proc presignSinkOut(msg: string, cfg: SinkConfig, t: Topic, ignored: StringTable) =
  let
    params      = cfg.httpParams()
    signHeaders = params.headers.addChalkCoreHeaders(body = msg)
    signResponse = safeRequest(
      url                = params.uri,
      timeout            = params.timeout,
      headers            = signHeaders,
      disallowHttp       = params.disallowHttp,
      pinnedCert         = params.pinnedCert,
      preferBundledCerts = params.preferBundledCerts,
      httpMethod         = HttpPut,
      retries            = 2,
      firstRetryDelayMs  = 100,
      maxRedirects       = 0,
      rejectStatusCodes  = [500..599],
    )

  if signResponse.code notin [Http302, Http307]:
    raise newException(ValueError, "Presign requires 302/307 redirect but received: " & signResponse.status)

  if not signResponse.headers.hasKey("location"):
    raise newException(ValueError, "Presign redirect Location header missing")

  let uri = parseUri(signResponse.headers["location"])

  if uri.scheme == "":
    raise newException(ValueError, "Presign redirect Location header needs to be absolute URL")

  let
    uploadHeaders = newHttpHeaders().addForwardedHeaders(signResponse)
    response      = safeRequest(
      url                = uri,
      headers            = uploadHeaders,
      timeout            = params.timeout,
      disallowHttp       = params.disallowHttp,
      pinnedCert         = params.pinnedCert,
      preferBundledCerts = params.preferBundledCerts,
      httpMethod         = HttpPut,
      body               = msg,
      retries            = 2,
      firstRetryDelayMs  = 100,
      acceptStatusCodes  = [200..299],
    )

  cfg.iolog(t, "Presign " & response.status)

proc addFileSink*() =
  var
    record   = SinkImplementation()
    keys     = {
      "filename"       : true,
      "mode"           : false,
      "log_search_path": false,
      "use_search_path": false,
    }.toTable()

  record.outputFunction = fileSinkOut
  record.closeFunction  = some(CloseCallback(fileSinkClose))
  record.keys           = keys

  registerSink("file", record)

proc addRotoLogSink*() =
  var
    record = SinkImplementation()
    keys   = {
      "filename"          : true,
      "max"               : true,
      "log_search_path"   : false,
      "truncation_amount" : false,
    }.toTable()

  record.initFunction   = some(InitCallback(rotoLogSinkInit))
  record.outputFunction = rotoLogSinkOut
  record.closeFunction  = some(CloseCallback(fileSinkClose))
  record.keys           = keys

  registerSink("rotating_log", record)

proc addS3Sink*() =
  var
    record = SinkImplementation()
    keys   = {
      "uid"      : true,
      "secret"   : true,
      "token"    : false,
      "uri"      : true,
      "region"   : false,
      "extra"    : false,
      "endpoint" : false,
    }.toTable()

  record.initFunction   = some(InitCallback(s3SinkInit))
  record.outputFunction = s3SinkOut
  record.keys           = keys

  registerSink("s3", record)

proc addPostSink*() =
  var
    record = SinkImplementation()
    keys = {
      "uri"                  : true,
      "content_type"         : true,
      "disallow_http"        : false,
      "headers"              : false,
      "timeout"              : false,
      "pinned_cert_file"     : false,
      "prefer_bundled_certs" : false,
      "auth"                 : false,
    }.toTable()

  record.outputFunction = postSinkOut
  record.keys           = keys

  registerSink("post", record)

proc addPresignSink*() =
  var
    record = SinkImplementation()
    keys = {
      "uri"                  : true,
      "content_type"         : true,
      "disallow_http"        : false,
      "headers"              : false,
      "timeout"              : false,
      "pinned_cert_file"     : false,
      "prefer_bundled_certs" : false,
      "auth"                 : false,
    }.toTable()

  record.outputFunction = presignSinkOut
  record.keys           = keys

  registerSink("presign", record)

proc addDefaultSinks*() =
  addStdoutSink()
  addStderrSink()
  addFileSink()
  addRotoLogSink()
  addS3Sink()
  addPostSink()
  addPresignSink()
