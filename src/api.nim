##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import base64, config, httpclient, net, os, QRgen, terminal, uri

template jwtSplitAndDecode(jwtString: string, doDecode: bool): string =
  # this is pretty crude in terms of JWT structure validation to say the least
  let parts = split(jwtString, '.')
  if len(parts) != 3:
    raise newException(Exception, "Invalid JWT format")

  if doDecode:
    let decodedApiJwt = decode(apiJwtPayload)
    $decodedApiJwt
  else:
    $(parts[1]) #apiJwtPayload

proc refreshAccessToken*(refresh_token: string): string =

  # Mechanism to support access_token refresh via OIDC
  let timeout:   int = cast[int](chalkConfig.getSecretManagerTimeout())
  var
      refresh_url = uri.parseUri(chalkConfig.getSecretManagerUrl())
      context:           SslContext
      client:            HttpClient

  refresh_url.path = "/api/refresh"

  # request new access_token via refresh
  info("Refreshing API access token....")
  if refresh_url.scheme == "https":
    context = newContext(verifyMode = CVerifyPeer)
    client  = newHttpClient(sslContext = context, timeout = timeout)
  else:
    client  = newHttpClient(timeout = timeout)
  let response  = client.safeRequest(url = refresh_url, httpMethod = HttpPost, body = $refresh_token)
  client.close()

  if response.status.startswith("200"):
    # parse json response and save / return values
    let
      jsonNode         = parseJson(response.body())
      new_access_token = jsonNode["access_token"].getStr()

    return new_access_token

proc getChalkApiToken*(): (string, string) =

  # ToDo check if token already self chalked in and gecan be read

  var
    apiJwtPayload:     string
    authId:            string
    authnSuccess:      bool   = false
    authnFailure:      bool   = false
    authUrl:           string
    client:            HttpClient
    clientPoll:        HttpClient
    userCode:          string
    deviceCode:        string
    context:           SslContext
    contextPoll:       SslContext
    frameIndex:        int    = 0
    framerate:         float
    pollPayloadBase64: string
    pollUri:           Uri
    pollUrl:           string
    pollInt:           int
    refreshToken:      string
    response:          Response
    responsePoll:      Response
    ret                = ("","")
    accessToken:       string
    totalSleepTime:    float  = 0.0
  type
    frameList = array[8, string]
  let
    frames: frameList = [
          "[    ]",
          "[   =]",
          "[  ==]",
          "[ ===]",
          "[====]",
          "[=== ]",
          "[==  ]",
          "[=   ]",
          ]
    failFr: string = "[☠☠☠☠]"
    succFr: string = "[❤❤❤❤]"
    timeout:   int = cast[int](chalkConfig.getSecretManagerTimeout())

  # set api login endpoint
  var login_url = uri.parseUri(chalkConfig.getSecretManagerUrl())
  login_url.path = "/api/login"

  # request auth code from API
  info("Requesting Chalk authentication code " & $login_url)
  if login_url.scheme == "https":
    context = newContext(verifyMode = CVerifyPeer)
    client  = newHttpClient(sslContext = context, timeout = timeout)
  else:
    client  = newHttpClient(timeout = timeout)
  response  = client.safeRequest(url = login_url, httpMethod = HttpPost, body = "")
  client.close()

  if response.status.startswith("200"):
    # parse json response and save / return values
    let jsonNode = parseJson(response.body())
    authId       = jsonNode["id"].getStr()
    authUrl      = jsonNode["authUrl"].getStr()
    userCode     = jsonNode["userCode"].getStr()
    deviceCode   = jsonNode["deviceCode"].getStr()
    pollUrl      = jsonNode["pollUrl"].getStr()
    pollInt      = jsonNode["pollIntervalSeconds"].getInt()

    # show user url to authentication against + qr code
    print("<h2>To login please follow this link in a browser:</h2>\n\n\t" & $authUrl & "\n")
    print("<h2>Or, use this QR code to login with your smart phone:</h2>")
    let authnQR = newQR($authUrl)
    authnQR.printTerminal

    # sit in sync loop polling the URL to see if user has authenticated
    print("<h2>Waiting for authentication to complete...</h2>\n")
    while not authnSuccess and not authnFailure:
        # poll the API with deviceCode to see if login succeeded yet
        pollUri = parseUri(pollUrl & deviceCode)

        if pollUri.scheme == "https":
          contextPoll = newContext(verifyMode = CVerifyPeer)
          clientPoll  = newHttpClient(sslContext = contextPoll, timeout = timeout)
        else:
          clientPoll  = newHttpClient(timeout = timeout)

        responsePoll  = clientPoll.safeRequest(url = pollUri, httpMethod = HttpGet, body = "")
        clientPoll.close()

        # check response - HTTP 200 = yes, HTTP 428 = Not yet
        if responsePoll.status.startswith("200"):
          authnSuccess = true
          eraseLine()
          stdout.write(succFr)
          stdout.flushFile()
          print("<h5>Authentication successful!</h5>\n")

          # parse json response and save / return values()
          let jsonPollNode = parseJson(responsePoll.body())
          accessToken            = jsonPollNode["access_token"].getStr()
          refreshToken     = jsonPollNode["refresh_token"].getStr()

          # decode JWT
          pollPayloadBase64  = jwtSplitAndDecode($accessToken, true)
          ret = ($accessToken, $refreshToken)

        elif responsePoll.status.startswith("428") or responsePoll.status.startswith("403"):
          # sleep for requested polling period while showing spinner before polling again

          # restart spinner animation - reset vars
          frameIndex     = 0
          framerate      = (pollInt * 1000) / frames.len
          totalSleepTime = 0.0

          # display spinner one frame at a time until poll timeout exceeded
          while true:
            eraseLine()
            stdout.write(frames[frameIndex])
            stdout.flushFile()
            frameIndex = (frameIndex + 1) mod frames.len
            sleep(int(framerate))
            totalSleepTime += framerate
            if totalSleepTime >= float(pollInt * 1000):
              break
        else:
          authnFailure = true
          eraseLine()
          stdout.write(failFr)
          stdout.flushFile()
          print("<h4>Authentication failed\n</h4>")
          error("Unhandled HTTP Error when polling authentication status. Aborting")
          trace(responsePoll.status)
          trace(responsePoll.body())
          break

  else:
    authnFailure = true
    eraseLine()
    stdout.write(failFr)
    stdout.flushFile()
    echo "\n"
    error("Unhandled HTTP Error when getting authntication code. Aborting")

  return ret
