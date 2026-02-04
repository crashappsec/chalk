import std/[
  sequtils,
  uri,
]

proc withQueryPair*(uri: var Uri, k, v: string): Uri =
  var query = decodeQuery(uri.query).toSeq()
  query.add((k, v))
  uri.query = encodeQuery(query)
  return uri
