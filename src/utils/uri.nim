import std/[
  sequtils,
  uri,
]

export uri

proc parseUriDefaultScheme*(url: string, defaultScheme = "https"): Uri =
  result = parseUri(url)
  if result.scheme == "":
    result = parseUri(defaultScheme & "://" & url)

proc withPort*(self: Uri): Uri =
  result = deepCopy(self)
  if result.port == "":
    case result.scheme
    of "https":
      result.port = "443"
    of "http":
      result.port = "80"

proc withHostname*(self: Uri, hostname: string): Uri =
  result = deepCopy(self)
  result.hostname = hostname

proc withQueryPair*(self: Uri, k, v: string): Uri =
  result = deepCopy(self)
  var query = decodeQuery(result.query).toSeq()
  query.add((k, v))
  result.query = encodeQuery(query)

proc withDefaultPort*(self: Uri, port = ""): Uri =
  result = deepCopy(self)
  if result.port == "":
    result.port = port

proc address*(self: Uri): string =
  result = self.hostname
  if self.port != "":
    result &= ":" & self.port
