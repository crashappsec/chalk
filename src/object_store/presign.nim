##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  sequtils,
  uri,
]
import ".."/[
  auth,
  config,
  types,
  utils/http,
]

type
  ObjectStorePresign = ref object of ObjectStoreConfig
    uri*:            string
    headers*:        HttpHeaders
    disallowHttp*:   bool
    timeout*:        int
    pinnedCertFile*: string
    readAuth*:       AuthConfig
    writeAuth*:      AuthConfig

proc getConfig[T](name: string, field: string): T =
  return attrGet[T]("object_store_config." & name & ".object_store_presign." & field)

proc init(self: ObjectStore, name: string): ObjectStoreConfig =
  let
    readAuthName  = getConfig[string](name, "read_auth")
    readAuthOpt   = getAuthConfigByName(readAuthName)
    writeAuthName = getConfig[string](name, "write_auth")
    writeAuthOpt  = getAuthConfigByName(writeAuthName)
  if readAuthName != "" and readAuthOpt.isNone():
    raise newException(ValueError, "read auth config '" & readAuthName & "' is missing")
  if writeAuthName != "" and writeAuthOpt.isNone():
    raise newException(ValueError, "write auth config '" & writeAuthName & "' is missing")
  let
    headers = getConfig[TableRef[string, string]](name, "headers")
    config  = ObjectStorePresign(
      name:           name,
      store:          self,
      headers:        newHttpHeaders(headers.pairs().toSeq()),
      uri:            getConfig[string](name, "uri"),
      disallowHttp:   getConfig[bool](  name, "disallow_http"),
      timeout:        getConfig[int](   name, "timeout"),
      pinnedCertFile: getConfig[string](name, "pinned_cert_file"),
      readAuth:       readAuthOpt.get(nil),
      writeAuth:      writeAuthOpt.get(nil),
    )
  return ObjectStoreConfig(config)

proc url(this: ObjectStoreConfig, keyRef: ObjectStoreRef): Uri =
  let self = ObjectStorePresign(this)
  result = parseUri(self.uri)
  result.path.removeSuffix('/')
  result.path = result.path & "/" & keyRef.key & "." & keyRef.id

proc fqn(this: ObjectStoreConfig, keyRef: ObjectStoreRef): Uri =
  let self = ObjectStorePresign(this)
  result = self.url(keyRef)
  result.scheme = self.store.name & "+" & result.scheme

proc request(self:           ObjectStorePresign,
             keyRef:         ObjectStoreRef,
             auth:           AuthConfig,
             httpMethod:     HttpMethod,
             body:           string,
             ): (Response, ObjectStoreRef) =
  var signHeaders = newHttpHeaders(@[
    ("Content-Type", "application/json"),
    ("X-Content-Length", $len(body)),
    ("X-Chalk-Digest-Sha256", keyRef.digest),
    ("X-Chalk-Version", getChalkExeVersion()),
    # TODO expose better API for action id interaction
    ("X-Chalk-Action-Id", unpack[string](hostInfo["_ACTION_ID"])),
  ]).update(self.headers)
  if auth != nil:
    signHeaders = auth.implementation.injectHeaders(auth, signHeaders)

  let url = self.url(keyRef)
  trace("object store: " & $httpMethod & " " & $url)
  # for the sign request, we do not want to send full request payload as:
  # * we expect a redirect response
  # * server might not accept large requests (hence presigning)
  # * no need to waste bandwidth
  # and will only send it to the returned signed URL
  # which is why we disallow redirects here via maxRedirects
  # NOTE this assumes that the endpoint immediately returns presigned URL
  let signResponse = safeRequest(url               = self.url(keyRef),
                                 timeout           = self.timeout,
                                 headers           = signHeaders,
                                 disallowHttp      = self.disallowHttp,
                                 pinnedCert        = self.pinnedCertFile,
                                 httpMethod        = httpMethod,
                                 retries           = 2,
                                 firstRetryDelayMs = 100,
                                 maxRedirects      = 0,
                                 raiseWhenAbove    = 400)
  trace("object store: " & $httpMethod & " " & $url & " -> " & $signResponse.code)

  if signResponse.code notin [Http302, Http307]:
    trace("object store: " & signResponse.body())
    raise newException(ValueError, "Presign requires 302/307 redirect but received: " & signResponse.status)

  if not signResponse.headers.hasKey("location"):
    raise newException(ValueError, "Presign edirect Location header missing")

  let uri = parseUri(signResponse.headers["location"])
  if uri.scheme == "":
    trace("object store: " & $uri)
    raise newException(ValueError, "Presign edirect Location header needs to be absolute URL")

  var
    names   = newSeq[string]()
    headers = newHttpHeaders(@[
      ("Content-Type", "application/json"),
      ("Content-Length", $len(body)),
    ])
  if signResponse.headers.hasKey("x-forward-headers"):
    names = signResponse.headers["x-forward-headers"].strip().split(',')
    for i in names:
      let name = i.strip()
      if signResponse.headers.hasKey(name):
        headers[name] = signResponse.headers[name]

  trace("object store: " & $httpMethod & " @" & uri.hostname & " (" & $len(body) & "bytes) forwarding: " & $names)
  let response = safeRequest(url               = uri,
                             headers           = headers,
                             timeout           = self.timeout,
                             disallowHttp      = self.disallowHttp,
                             pinnedCert        = self.pinnedCertFile,
                             httpMethod        = httpMethod,
                             body              = body,
                             retries           = 2,
                             firstRetryDelayMs = 100,
                             raiseWhenAbove    = 500)
  trace("object store: " & $httpMethod & " @" & $uri.hostname & " (" & $len(body) & "bytes) -> " & $response.code)

  let updatedRef = deepCopy(keyRef)
  updatedRef.query = signResponse.headers.getOrDefault("x-chalk-object-query")
  return (response, updatedRef)

proc objectExists(this: ObjectStoreConfig, keyRef: ObjectStoreRef): ObjectStoreRef =
  let
    self = ObjectStorePresign(this)
    (response, updatedRef) = self.request(
      keyRef,
      auth       = self.readAuth,
      httpMethod = HttpHead,
      body       = "",
    )
  if response.code.is2xx():
    return updatedRef
  elif response.code == Http404:
    return nil
  else:
    raise newException(ValueError, $response.code & " " & response.body())

proc createObject(this: ObjectStoreConfig, keyRef: ObjectStoreRef, data: string): ObjectStoreRef =
  let
    self = ObjectStorePresign(this)
    (response, updatedRef) = self.request(
      keyRef,
      auth       = self.writeAuth,
      httpMethod = HttpPut,
      body       = data,
    )
  if response.code.is2xx():
    return updatedRef
  else:
    raise newException(ValueError, $response.code & " " & response.body())

let presignObjectStore* = ObjectStore(
  name:         "presign",
  init:         init,
  uri:          fqn,
  objectExists: objectExists,
  createObject: createObject,
)
