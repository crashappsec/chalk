##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## HTTP requests bounded by an absolute deadline and a response size.
##
## The body is consumed in small pieces; every wait is limited to the
## budget that remains, and the response is abandoned once it exceeds
## `maxBodyBytes`, whatever Content-Length claims.

import std/[
  asyncdispatch,
  asyncnet,
  importutils,
  httpclient,
  net,
  openssl,
  streams,
  strutils,
]
import pkg/nimutils/net
import "."/[resolve_deadline, times, uri]

type
  HttpBudget* = object
    deadline*:     MonoTime
    maxBodyBytes*: int

  BoundedResponse* = object
    response*:     Response
    effectiveUri*: Uri

  HttpOriginError* = object of CatchableError
  HttpTlsError* = object of CatchableError
  HttpTlsProtocolError* = object of HttpTlsError
  HttpPeerVerificationError* = object of HttpTlsError
  HttpDeadlineError* = object of CatchableError
  HttpBodyTooLargeError* = object of CatchableError

const redirectCodes = {Http301, Http302, Http303, Http307, Http308}

proc remaining(budget: HttpBudget): int =
  result = remainingMs(budget.deadline)
  if result <= 0:
    raise newException(HttpDeadlineError, "request timed out")

proc within[T](fut: Future[T], budget: HttpBudget): T =
  if not waitFor(fut.withTimeout(budget.remaining())):
    raise newException(HttpDeadlineError, "request timed out")
  return fut.read()

proc tooLarge(budget: HttpBudget): ref HttpBodyTooLargeError =
  newException(HttpBodyTooLargeError,
               "response body exceeds " & $budget.maxBodyBytes & " bytes")

proc sslContextFor(pinnedCert: string, verifyMode: SslCVerifyMode): SslContext =
  if pinnedCert != "":
    return newContext(verifyMode = verifyMode, caFile = pinnedCert)
  try:
    return newContext(verifyMode = verifyMode)
  except CatchableError:
    return newContext(verifyMode = verifyMode, caFile = getCAStorePath())

proc copyHeaders(headers: HttpHeaders): HttpHeaders =
  result = newHttpHeaders()
  if headers != nil:
    for key, value in headers.pairs():
      result.add(key, value)

proc readBody(response: AsyncResponse, httpMethod: HttpMethod,
              budget: HttpBudget): string =
  if httpMethod != HttpHead:
    let declared: string = response.headers.getOrDefault("Content-Length")
    if declared != "" and parseInt(declared) > budget.maxBodyBytes:
      raise tooLarge(budget)
  result = ""
  while true:
    let (more, piece) = response.bodyStream.read().within(budget)
    if not more:
      break
    if len(result) + len(piece) > budget.maxBodyBytes:
      raise tooLarge(budget)
    result.add(piece)

proc redirectTarget(current: Uri, headers: HttpHeaders): Uri =
  let location: string = headers.getOrDefault("Location")
  if location == "":
    raise newException(ValueError, "redirect without a Location header")
  result = combine(current, parseUri(location))
  result.isIpv6 = ':' in result.hostname

proc handshakeFinished(ssl: SslPtr): cint
  {.cdecl, importc: "SSL_is_init_finished", dynlib: DLLSSLName.}
proc peerVerifyResult(ssl: SslPtr): clong
  {.cdecl, importc: "SSL_get_verify_result", dynlib: DLLSSLName.}
proc setPeerHost(ssl: SslPtr, hostname: cstring): cint
  {.cdecl, importc: "SSL_set1_host", dynlib: DLLSSLName.}
proc peerParameters(ssl: SslPtr): pointer
  {.cdecl, importc: "SSL_get0_param", dynlib: DLLSSLName.}
proc setPeerIp(parameters: pointer, address: cstring): cint
  {.cdecl, importc: "X509_VERIFY_PARAM_set1_ip_asc", dynlib: DLLUtilName.}

proc connectWithin(client: AsyncHttpClient, context: SslContext,
                   target: Uri, budget: HttpBudget, verifyMode: SslCVerifyMode) =
  if target.scheme notin ["http", "https"]:
    raise newException(ValueError, "unsupported registry URL scheme")
  client.close()
  let port = uriOrigin(target).port
  var addresses: seq[string]
  try:
    addresses = resolveWithin(target.hostname, port, budget.remaining())
  except NetworkTimeoutError:
    raise newException(HttpDeadlineError, "request timed out")
  var lastFailure: ref CatchableError
  for index, address in addresses:
    let remaining = budget.remaining()
    let attemptMs = max(1, remaining div (addresses.len - index))
    var socket: AsyncSocket
    try:
      socket = connectNumericWithin(address, Port(parseInt(port)), attemptMs)
    except NetworkTimeoutError as error:
      if timedOut(budget.deadline):
        raise newException(HttpDeadlineError, "request timed out")
      lastFailure = error
      continue
    except CatchableError as error:
      lastFailure = error
      continue
    try:
      if target.scheme == "https":
        context.wrapConnectedSocket(socket, handshakeAsClient, target.hostname)
        if verifyMode != CVerifyNone:
          let configured =
            if isIpAddress(target.hostname):
              setPeerIp(peerParameters(socket.sslHandle()), target.hostname.cstring)
            else:
              setPeerHost(socket.sslHandle(), target.hostname.cstring)
          if configured != 1:
            raise newException(HttpPeerVerificationError, "could not configure registry certificate identity checks")
      # The stdlib otherwise resolves the hostname synchronously in request().
      privateAccess(HttpClientBase[AsyncSocket])
      client.socket = socket
      client.currentURL = target
      client.connected = true
      return
    except:
      socket.close()
      raise
  if lastFailure of NetworkTimeoutError:
    raise newException(HttpDeadlineError, "request timed out")
  if lastFailure != nil:
    raise lastFailure
  raise newException(IOError, "registry hostname has no usable addresses")

proc isTlsProtocolMismatch*(message: string): bool =
  let text = message.toLowerAscii()
  return "wrong version number" in text or "unknown protocol" in text or
         "packet length too long" in text or "record layer failure" in text

proc boundedRequest*(url: Uri,
                     httpMethod: HttpMethod,
                     budget: HttpBudget,
                     body = "",
                     headers: HttpHeaders = nil,
                     pinnedCert = "",
                     verifyMode = CVerifyPeer,
                     maxRedirects = 3,
                     sameOriginRedirects = false,
                     ): BoundedResponse =
  ## One request with up to `maxRedirects` redirects, every
  ## response body bounded by `budget`. Raises `HttpDeadlineError` or
  ## `HttpBodyTooLargeError`; status codes are returned, not checked.
  discard budget.remaining()
  var
    target     = url
    reqMethod  = httpMethod
    reqBody    = body
    reqHeaders = copyHeaders(headers)
    hops       = 0
  target.isIpv6 = ':' in target.hostname
  let
    context = sslContextFor(pinnedCert, verifyMode)
    client  = newAsyncHttpClient(userAgent    = getDefaultUserAgent(),
                                 maxRedirects = 0,
                                 sslContext   = context)
  try:
    while true:
      discard budget.remaining()
      connectWithin(client, context, target, budget, verifyMode)
      if not reqHeaders.hasKey("Host"):
        reqHeaders["Host"] = target.address & (if target.port != "": ":" & target.port else: "")
      let pending = client.request(target, reqMethod, reqBody, reqHeaders)
      let
        response = pending.within(budget)
        data     = readBody(response, reqMethod, budget)
        code     = response.code()
      if code notin redirectCodes or hops == maxRedirects:
        return BoundedResponse(
          response: Response(
            version:    response.version,
            status:     response.status,
            headers:    response.headers,
            bodyStream: newStringStream(data),
          ),
          effectiveUri: target,
        )
      let next = redirectTarget(target, response.headers)
      if target.scheme == "https" and next.scheme != "https":
        raise newException(HttpTlsError, "registry redirect would downgrade TLS")
      if sameOriginRedirects and not sameOrigin(url, next):
        raise newException(HttpOriginError, "referrer pagination left the registry origin")
      if code in {Http301, Http302, Http303}:
        if reqMethod notin {HttpGet, HttpHead}:
          reqMethod = HttpGet
        reqBody = ""
        for name in ["Content-Length", "Content-Type", "Transfer-Encoding"]:
          reqHeaders.del(name)
      if not sameOrigin(next, target):
        reqHeaders.del("Host")
        reqHeaders.del("Authorization")
      target = next
      inc hops
  except SslError:
    let socket = client.getSocket()
    when defined(testing):
      echo "TLS fixture reason: ", getCurrentExceptionMsg()
      echo "TLS fixture socket: ", socket != nil
      if socket != nil:
        echo "TLS fixture handle: ", socket.sslHandle() != nil
        if socket.sslHandle() != nil:
          echo "TLS fixture verification: ", peerVerifyResult(socket.sslHandle())
          echo "TLS fixture handshake finished: ", handshakeFinished(socket.sslHandle())
    if socket != nil and socket.sslHandle() != nil:
      if verifyMode != CVerifyNone and peerVerifyResult(socket.sslHandle()) != 0:
        raise newException(HttpPeerVerificationError, "registry TLS peer identity verification failed")
      if handshakeFinished(socket.sslHandle()) == 0 and isTlsProtocolMismatch(getCurrentExceptionMsg()):
        raise newException(HttpTlsProtocolError, "registry endpoint did not complete TLS")
    raise newException(HttpTlsError, "registry TLS exchange failed")
  finally:
    client.close()
    context.destroyContext()
