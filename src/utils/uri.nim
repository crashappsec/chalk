import std/[
  sequtils,
  options,
  strutils,
  uri,
]

export uri

proc parseUriDefaultScheme*(url: string, defaultScheme = "https"): Uri =
  result = parseUri(url)
  if result.scheme == "" or result.hostname == "":
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
  if self.isIpv6:
    return "[" & self.hostname & "]"
  else:
    return self.hostname

proc endpoint*(self: Uri): string =
  result = self.address
  if self.port != "":
    result &= ":" & self.port

proc uriOrigin*(url: Uri): tuple[scheme, hostname, port: string] =
  let scheme = url.scheme.toLowerAscii()
  let port =
    if url.port != "": url.port
    elif scheme == "https": "443"
    elif scheme == "http": "80"
    else: ""
  return (scheme, url.hostname.toLowerAscii(), port)

proc sameOrigin*(a, b: Uri): bool = uriOrigin(a) == uriOrigin(b)

proc resolveSameOrigin*(base: Uri, reference: string): Option[Uri] =
  let text = reference.strip()
  if text == "" or text.startsWith("//"):
    return none(Uri)
  var target = combine(base, parseUri(text))
  target.isIpv6 = ':' in target.hostname
  if target.username != "" or target.password != "" or not sameOrigin(base, target):
    return none(Uri)
  return some(target)
