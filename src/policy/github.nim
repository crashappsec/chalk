##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## GitHub dependency review for build policies: the commits a GitHub Actions
## pull request (or merge group, or push) job compares, and the dependency
## changes GitHub's dependency graph reports between them, read as
## actions/dependency-review-action reads them.
## https://docs.github.com/en/rest/dependency-graph/dependency-review
## https://github.com/actions/dependency-review-action/blob/main/src/git-refs.ts
## https://github.com/actions/dependency-review-action/blob/main/src/dependency-graph.ts

import std/[
  json,
  os,
  strutils,
  tables,
  uri,
]
import ".."/[
  types,
  utils/base64,
  utils/http,
]

const
  # https://docs.github.com/en/rest/about-the-rest-api/api-versions
  apiVersion             = "2026-03-10"
  snapshotWarningsHeader = "x-github-dependency-graph-snapshot-warnings"
  defaultReviewEvents*   = ["pull_request", "pull_request_target", "merge_group"]
  reviewEvents*          = ["pull_request", "pull_request_target", "merge_group", "push"]
  perPage                = 100
  maxPages               = 100
  requestTimeoutMs       = 30_000

type
  ReviewRefs* = object
    event*: string # GitHub event the job runs for
    repo*:  string # `owner/name`
    api*:   string # REST API URL, e.g. of a GitHub Enterprise Server
    base*:  string
    head*:  string

  DependencyVulnerability* = object
    severity*: string # as GitHub rates advisories: low, moderate, high, critical
    ghsaId*:   string
    summary*:  string
    url*:      string

  DependencyChange* = object
    changeType*: string # added or removed
    manifest*:   string # repository-relative path
    ecosystem*:  string
    name*:       string
    version*:    string
    packageUrl*: string
    scope*:      string # runtime, development or unknown
    vulnerabilities*: seq[DependencyVulnerability]

  ReviewStatus* = enum
    rsReviewed,
    ## the repository or job cannot use dependency review, e.g. without
    ## GitHub Code Security or a token: not an evaluation error
    rsUnavailable,
    rsFailed

  DependencyReview* = object
    status*:  ReviewStatus
    reason*:  string # why it is unavailable or failed
    changes*: seq[DependencyChange]
    snapshotWarnings*: string

  GithubResponse* = object
    code*:    int
    body*:    string
    headers*: HttpHeaders

  ## Replaced by unit tests
  GithubFetcher* = proc(url: string, headers: HttpHeaders): GithubResponse

proc fetch(url: string, headers: HttpHeaders): GithubResponse =
  let response = safeRequest(url        = url,
                             httpMethod = HttpGet,
                             headers    = headers,
                             timeout    = requestTimeoutMs)
  GithubResponse(code: int(response.code()), body: response.body(), headers: response.headers)

var
  githubFetcher*: GithubFetcher = fetch
  reviews = initTable[string, DependencyReview]()
  warned: seq[string]

proc clearDependencyReviewCache*() =
  reviews.clear()
  warned = @[]

proc warnOnce*(message: string) =
  ## every policy enabling the review would repeat it
  if message notin warned:
    warned.add(message)
    warn(message)

proc isZeroSha(sha: string): bool =
  sha != "" and sha.allCharsInSet({'0'})

proc eventRefs*(event: string, payload: JsonNode): tuple[base, head: string] =
  ## The commits an event compares, as the action reads them; empty for a
  ## push that creates or deletes a branch, which has nothing to compare.
  ## Raises `ValueError` when the payload lacks them.
  case event
  of "pull_request", "pull_request_target":
    result = (payload{"pull_request", "base", "sha"}.getStr(),
              payload{"pull_request", "head", "sha"}.getStr())
  of "merge_group":
    result = (payload{"merge_group", "base_sha"}.getStr(),
              payload{"merge_group", "head_sha"}.getStr())
  of "push":
    # https://docs.github.com/en/webhooks/webhook-events-and-payloads#push
    let
      before = payload{"before"}.getStr()
      after  = payload{"after"}.getStr()
    if payload{"created"}.getBool(false) or payload{"deleted"}.getBool(false) or
       before.isZeroSha() or after.isZeroSha():
      return ("", "")
    result = (before, after)
  else:
    raise newException(ValueError, "dependency review does not support the " & event & " event")
  if result.base == "" or result.head == "":
    raise newException(ValueError, "the " & event & " event payload has no base and head commits")

proc reviewRefs*(events: openArray[string]): Option[ReviewRefs] =
  ## The commits to review when chalk runs in a GitHub Actions job for one
  ## of `events`, else none. Raises `ValueError` when the job's event
  ## payload cannot be read.
  if getEnv("GITHUB_ACTIONS") != "true":
    trace("policy: dependency review only runs in GitHub Actions")
    return none(ReviewRefs)
  let event = getEnv("GITHUB_EVENT_NAME")
  if event notin events:
    trace("policy: no dependency review for GitHub event " & escapeJson(event) &
          " (reviewed: " & events.join(", ") & ")")
    return none(ReviewRefs)
  let repo = getEnv("GITHUB_REPOSITORY").strip(chars = {'/'})
  if repo == "":
    raise newException(ValueError, "GITHUB_REPOSITORY is not set")
  let path = getEnv("GITHUB_EVENT_PATH")
  if path == "":
    raise newException(ValueError, "GITHUB_EVENT_PATH is not set")
  var payload: JsonNode
  try:
    payload = parseFile(path)
  except CatchableError:
    raise newException(ValueError, "could not read the " & event & " event payload: " &
                                   getCurrentExceptionMsg())
  let (base, head) = eventRefs(event, payload)
  if base == "":
    trace("policy: no dependency review for a push creating or deleting a branch")
    return none(ReviewRefs)
  var api = getEnv("GITHUB_API_URL")
  if api == "":
    api = "https://api.github.com"
  some(ReviewRefs(event: event, repo: repo, api: api.strip(leading = false, chars = {'/'}),
                  base: base, head: head))

proc `$`*(refs: ReviewRefs): string =
  refs.repo & " " & refs.base & "..." & refs.head

proc header(response: GithubResponse, name: string): string =
  if response.headers != nil and response.headers.hasKey(name):
    return response.headers[name]
  return ""

proc parseChanges*(body: string): seq[DependencyChange] =
  ## One page of the comparison. Raises `ValueError` when it is not one.
  let doc = parseJson(body)
  if doc.kind != JArray:
    raise newException(ValueError, "the dependency graph comparison is not a list")
  for item in doc:
    if item.kind != JObject:
      raise newException(ValueError, "the dependency graph comparison lists a non-object")
    var scope = item{"scope"}.getStr()
    if scope == "":
      # GitHub Enterprise Server may omit it; runtime, as the action assumes:
      # https://github.com/actions/dependency-review-action/blob/main/src/filter.ts
      scope = "runtime"
    var change = DependencyChange(
      changeType: item{"change_type"}.getStr(),
      manifest:   item{"manifest"}.getStr(),
      ecosystem:  item{"ecosystem"}.getStr(),
      name:       item{"name"}.getStr(),
      version:    item{"version"}.getStr(),
      packageUrl: item{"package_url"}.getStr(),
      scope:      scope,
    )
    for v in item{"vulnerabilities"}.getElems():
      if v.kind != JObject:
        continue
      change.vulnerabilities.add(DependencyVulnerability(
        severity: v{"severity"}.getStr(),
        ghsaId:   v{"advisory_ghsa_id"}.getStr(),
        summary:  v{"advisory_summary"}.getStr(),
        url:      v{"advisory_url"}.getStr(),
      ))
    result.add(change)

proc snapshotWarnings*(value: string): string =
  ## the header is base64 encoded
  if value.strip() == "":
    return ""
  result = value.safeDecode()
  if result == "":
    result = value

proc requestHeaders(api, token: string): HttpHeaders =
  result = newHttpHeaders({"Authorization": "Bearer " & token,
                           "Accept":        "application/vnd.github+json"})
  # GitHub Enterprise Server releases support other API versions, and use
  # their default without the header
  if parseUri(api).hostname.toLowerAscii() == "api.github.com":
    result["X-GitHub-Api-Version"] = apiVersion

proc portOf(u: Uri): string =
  ## an explicit scheme-default port and none are the same origin
  if u.port != "":
    return u.port
  case u.scheme.toLowerAscii()
  of "http":  "80"
  of "https": "443"
  else:       ""

proc sameOrigin(a, b: string): bool =
  ## so the token is never sent to a host a `Link` header names
  let (x, y) = (parseUri(a), parseUri(b))
  x.scheme.toLowerAscii() == y.scheme.toLowerAscii() and
    x.hostname.toLowerAscii() == y.hostname.toLowerAscii() and x.portOf() == y.portOf()

proc isRateLimited(response: GithubResponse): bool =
  # https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api#exceeding-the-rate-limit
  response.code == 429 or
    (response.code == 403 and (response.header("x-ratelimit-remaining") == "0" or
                               response.header("retry-after") != "" or
                               "rate limit" in response.body.toLowerAscii()))

proc apiMessage(response: GithubResponse): string =
  ## GitHub's error `message`, else the body
  try:
    let message = parseJson(response.body){"message"}.getStr()
    if message != "":
      return message
  except CatchableError:
    discard
  return response.body.strip()[0 ..< min(len(response.body.strip()), 200)]

proc settingsUrl(refs: ReviewRefs): string =
  var server = getEnv("GITHUB_SERVER_URL")
  if server == "":
    server = "https://github.com"
  server.strip(leading = false, chars = {'/'}) & "/" & refs.repo & "/settings/security_analysis"

proc unavailable(reason: string): DependencyReview =
  DependencyReview(status: rsUnavailable, reason: reason)

proc failed(reason: string): DependencyReview =
  DependencyReview(status: rsFailed, reason: reason)

proc fetchComparison(refs: ReviewRefs, token: string): DependencyReview =
  # One request per page, no retries: the primary rate limit resets on
  # `x-ratelimit-reset`, minutes away, and a server error is left to
  # `on_error` like any other evaluation error.
  let headers = refs.api.requestHeaders(token)
  var
    url   = refs.api & "/repos/" & refs.repo & "/dependency-graph/compare/" &
            encodeUrl(refs.base) & "..." & encodeUrl(refs.head) & "?per_page=" & $perPage
    pages = 0
  while url != "":
    inc(pages)
    if pages > maxPages:
      return failed("the comparison has more than " & $(maxPages * perPage) & " dependency changes")
    let response = githubFetcher(url, headers)
    if response.isRateLimited():
      return failed("the GitHub API rate limit is exceeded (HTTP " & $response.code & ")")
    case response.code
    of 200 .. 299:
      discard
    of 401, 403:
      # https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/about-dependency-review#dependency-review-enablement
      return unavailable("GitHub returned HTTP " & $response.code & " (" & response.apiMessage() &
                         "); dependency review needs the dependency graph, and GitHub Code " &
                         "Security for private repositories, see " & refs.settingsUrl() &
                         ", and a GITHUB_TOKEN that can read the repository contents")
    of 404:
      return failed("GitHub could not compare the dependencies of " & $refs &
                    " (HTTP 404: " & response.apiMessage() & ")")
    else:
      return failed("GitHub returned HTTP " & $response.code & ": " & response.apiMessage())
    result.changes.add(parseChanges(response.body))
    let warnings = response.header(snapshotWarningsHeader).snapshotWarnings()
    if warnings != "":
      result.snapshotWarnings = warnings
    url = response.header("link").nextLink()
    if url != "" and not url.sameOrigin(refs.api):
      return failed("GitHub paginated to another host: " & url)
  result.status = rsReviewed

proc compareDependencies*(refs: ReviewRefs): DependencyReview =
  let token = getEnv("GITHUB_TOKEN")
  if token == "":
    return unavailable("GITHUB_TOKEN is not set")
  try:
    result = fetchComparison(refs, token)
  except CatchableError:
    return failed("could not compare the dependencies of " & $refs & ": " &
                  getCurrentExceptionMsg())

proc dependencyReview*(refs: ReviewRefs): DependencyReview =
  ## `compareDependencies`, once per process: every policy enabling the
  ## review compares the same commits
  let key = refs.api & " " & $refs
  if key notin reviews:
    reviews[key] = refs.compareDependencies()
  reviews[key]
