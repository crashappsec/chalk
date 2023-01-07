import config
import os
import streams
import strformat
import strutils
import tables
import options
import std/net
import std/uri
import std/httpclient
import nimutils
import nimutils/box
import nimutils/random
import nimaws/s3client
import con4m
import con4m/st
import con4m/eval
import con4m/typecheck

type
  SamiSinkInfo = object
    impl:     SamiSink
    enabled: bool
    
  SamiOuthookInfo = object
    sectionInfo: SamiOuthookSection
    theSink:     SamiSink
    
  SamiStream = seq[SamiOuthookInfo]

var sinkImpls:  Table[string, SamiSink]
var sinkPtrs:   Table[string, SamiSinkInfo]
var hooks:      Table[string, SamiOuthookInfo]
var outStreams: Table[string, seq[SamiOuthookInfo]]

proc registerSinkImplementation*(name: string, fn: SamiSink) =
  sinkImpls[name] = fn

proc registerSink*(name: string, info: SamiSinkSection): bool =
  if name notin sinkImpls:
    return false
    
  let callback = sinkImpls[name]

  sinkPtrs[name] = SamiSinkInfo(impl: callback, enabled: info.getEnabled())

  return true
  
proc registerHook*(name: string, sinkName: string, info: SamiOuthookSection) =
  let
    theSink = sinkPtrs[sinkName]
    o       = SamiOuthookInfo(sectionInfo: info, theSink: theSink.impl)

  if not theSink.enabled:
    return # Do this now so we don't have to check later.
    
  hooks[name] = o

proc registerStream*(name: string, hookList: seq[string]) =
  var hookObjs : seq[SamiOuthookInfo] = @[]

  for hookName in hookList:
    hookObjs.add(hooks[hookName])

  outStreams[name] = hookObjs

let
  startOfType = toCon4mType("f(string, int)->(string, bool)")
  strType     = Con4mType(kind: TypeString)
  
proc output*(stream:  string,
             ll:      LogLevel,
             content: string) =

  let hookObjs = outStreams[stream]
  var output   = content
  
  
  for hook in hookObjs:
    for filter in hook.sectionInfo.getFilters():
      var t = copyType(startOfType)
      var args: seq[Box] = @[pack(output), pack(getLogLevel())]

      for i in 1 ..< len(filter):
        t.params.add(strType)
        args.add(pack[string](filter[i]))

      let
        ret = sCall(getConfigState(), filter[0], args, t).get()
        tup = unpack[seq[Box]](ret)
      
      output = unpack[string](tup[0])

      if output == "" or not unpack[bool](tup[1]):
        break

    if output == "": return

    if getDryRun():
      for key, outhookInfo in hooks:
        if outHookInfo == hook:
          stderr.write(fmt"dry-run: stream {stream}: hook {key}: " &
                       fmt"would write: {output}")
          break
    else:
      if not hook.theSink(output, hook.sectionInfo):
        for key, outhookInfo in hooks:
          if outHookInfo == hook:
              error(fmt"FAILED WRITE: stream {stream}: hook {key}: " &
                          fmt"when writing: {output}")
          break
        
  
# proc jsonFormatOutputBlob(content: string, 
#                           ctx: SamiOutputContext): string {.inline.} =
#   let ctxStr = $ctx
#   return """{{ "context": "{ctxStr}", "ITEM LIST" : {content} }}""".fmt()


proc stdoutSink(content: string, cfg: SamiOuthookSection): bool =
  stdout.write(content)
  return true

proc stderrSink(content: string, cfg: SamiOuthookSection): bool =
  stderr.write(content)
  return true

var fileStreamCache: Table[string, FileStream]

proc fileSink(content: string, cfg: SamiOuthookSection): bool =
  let
    filename = cfg.getFileName().get()
    key      = cfg.getSink() & "!" & filename
  var
    f: FileStream

  if fileStreamCache.contains(key):
    f = fileStreamCache[key]
  else:
    f = newFileStream(filename, fmAppend)
    if f == nil:
      return false
    else:
      fileStreamCache[key] = f

  try:
    f.write(content)
    return true
  except:
    return false

var awsClientCache: Table[string, S3Client] 
  
proc awsSink(content: string, cfg: SamiOuthookSection): bool =
  let
    uri          = cfg.getUri().get()
    uid          = cfg.getUserId().get()
    secret       = cfg.getSecret().get()
    key          = cfg.getSink() & "!" & uid & "!" & uri
    dstUri       = parseURI(uri)
    bucket       = dstUri.hostname
    ts           = $(unixTimeInMS())
    randVal      = getRandomWords(2)
    baseObj      = dstUri.path[1 .. ^1] # Strip the leading /
    (head, tail) = splitPath(baseObj)
    `aux?`       = cfg.getAux()
  var
    objParts: seq[string] = @[ts, randVal]
    client:   S3Client

  if awsClientCache.contains(key):
    client = awsClientCache[key]
  else:
    client = newS3Client((uid, secret))

  if `aux?`.isSome():
    objParts.add(`aux?`.get())

  objParts.add(tail)

  let
    newTail = objParts.join("-")
    newPath = joinPath(head, newTail)
    res     = client.putObject(bucket, newPath, content)

  if res.code == Http200:
    return true
  else:
    return false

const customPostHeadersType = "f(string)->{string:string}"
const customPostHeadersName = "getPostHeaders"
getConfigState().newCallback(customPostHeadersName, customPostHeadersType)

proc postSink(content: string, cfg: SamiOuthookSection): bool =
  let dstUri = parseURI(cfg.getUri().get())

  var client = if dstUri.scheme == "https":
                 newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
               else:
                 newHttpClient()
                 
  if client == nil: return false

  let `headers?` = runCallBack(getConfigState(),
                               customPostHeadersName,
                               @[pack(cfg.getSink())],
                               some(toCon4mType(customPostHeadersType)))
  if `headers?`.isSome():
    let
      box     = `headers?`.get()
      headers = unpack[TableRef[string, string]](box)
    var
      asSeqOfTuples: seq[(string, string)] = @[]

    for k, v in headers.pairs():
      asSeqOfTuples.add((k, v)) 

    if len(headers) != 0:
      client.headers = newHTTPHeaders(asSeqOfTuples)

  let response = client.request(cfg.getUri().get(),
                                httpMethod = HttpPost,
                                body = content)

  if `$`(response.code)[0] == '2': return true
  return false
                            
  
const sinkCallbackType = "f(string, {string:string})->bool"
const sinkCallbackName = "userout"
getConfigState().newCallback(sinkCallbackName, sinkCallbackType)

proc customSink(content: string, cfg: SamiOuthookSection): bool =
  ## We call the con4m callback 'userout', passing it a dictionary
  ## containing any fields that are in the config.  
  ## the callback's signature is f(string, {string: string})->bool
  var
    fields: TableRef[string, string] = newTable[string, string]()
    args:   seq[Box]                 = @[pack(content)]

  let
    secret   = cfg.getSecret()
    userid   = cfg.getUserId()
    filename = cfg.getFileName()
    uri      = cfg.getUri()
    region   = cfg.getRegion()
    aux      = cfg.getAux()
    
  if secret.isSome():
    fields["secret"]   = secret.get()
  if userid.isSome():
    fields["userid"]   = userid.get()
  if filename.isSome():
    fields["filename"] = filename.get()
  if uri.isSome():
    fields["uri"]      = uri.get()
  if region.isSome():
    fields["region"]   = region.get()
  if aux.isSome():
    fields["aux"]      = aux.get()

  args.add(pack(fields))

  let `res?` = runCallBack(getConfigState(),
                           sinkCallbackName,
                           args,
                           some(toCon4mType(sinkCallbackType)))
  if `res?`.isNone():
    return false

  let box = `res?`.get()
  return unpack[bool](box)

registerSinkImplementation("stdout", stdoutSink)
registerSinkImplementation("stderr", stderrSink)
registerSinkImplementation("file", fileSink)
registerSinkImplementation("s3", awsSink)
registerSinkImplementation("post", postSink)
registerSinkImplementation("custom", customSink)
