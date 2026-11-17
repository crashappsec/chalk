##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Repository identity for `target_repos`: which repository a docker command
## builds, and whether a policy applies there.

import std/[
  os,
  strutils,
]
import ".."/[
  types,
]
import "."/[
  configuration,
  rules/golden_images,
]

const repoSchemes = ["http", "https", "ssh", "git", "git+ssh", "ssh+git"]

proc stripPort(authority: string): string =
  let colon = authority.rfind(':')
  if colon == -1 or authority.endsWith(']'):
    return authority
  for c in authority[colon + 1 .. ^1]:
    if not c.isDigit():
      return authority
  return authority[0 ..< colon]

proc normalize(url: string, pattern: bool): string =
  var s = url.strip()
  # docker git contexts select a ref and subdirectory after `#`; `?` starts a
  # query in a remote but is a wildcard in a pattern
  for sep in (if pattern: @['#'] else: @['#', '?']):
    let i = s.find(sep)
    if i != -1:
      s = s[0 ..< i]
  var host, path: string
  let schemeEnd = s.find("://")
  if schemeEnd != -1:
    if s[0 ..< schemeEnd].toLowerAscii() notin repoSchemes:
      return ""
    let
      rest  = s[schemeEnd + 3 .. ^1]
      slash = rest.find('/')
    var authority = if slash == -1: rest else: rest[0 ..< slash]
    path      = if slash == -1: "" else: rest[slash + 1 .. ^1]
    authority = authority[authority.rfind('@') + 1 .. ^1]
    host      = authority.stripPort()
  else:
    let
      colon = s.find(':')
      slash = s.find('/')
    if colon != -1 and (slash == -1 or colon < slash):
      # scp-like `[user@]host:path`
      host = s[0 ..< colon]
      host = host[host.rfind('@') + 1 .. ^1]
      path = s[colon + 1 .. ^1]
    elif pattern and slash > 0 and s[0] != '.' and s[0] != '~':
      # git reads a remote without scheme or `host:` as a local path, e.g. a
      # relative `mirrors/acme/app.git`, which must not pass for a repository
      # and hide the CI job's; patterns are written `host/path` though
      host = s[0 ..< slash]
      path = s[slash + 1 .. ^1]
    else:
      return ""
  path = path.strip(chars = {'/'})
  path.removeSuffix(".git")
  path = path.strip(chars = {'/'})
  # an owner (or group) and a name
  if host == "" or '/' notin path or "//" in path:
    return ""
  return (host & "/" & path).toLowerAscii()

proc normalizeRepo*(url: string): string =
  ## `host/path` of a git remote, lowercased, without scheme, credentials,
  ## port, query or `.git`, e.g. `git@github.com:Org/Repo.git` is
  ## `github.com/org/repo`. Empty when `url` names no remote repository,
  ## e.g. a local path (relative ones included, as git reads them) or
  ## chalk's `local` origin.
  normalize(url, pattern = false)

proc normalizeRepoPattern*(pattern: string): string =
  ## `normalizeRepo` for a `target_repos` glob: glob characters (`*`, `?`)
  ## are kept verbatim, so `https://github.com/Acme/app?.git` is
  ## `github.com/acme/app?`. Only a numeric port is removed: a glob in the
  ## port position (`github.com:*`) stays part of the host and, as
  ## repositories are compared without ports, never matches.
  normalize(pattern, pattern = true)

proc repoFromEnv*(): string =
  ## the repository of the CI job, when chalk runs in one
  let github = getEnv("GITHUB_REPOSITORY")
  if github != "":
    var server = getEnv("GITHUB_SERVER_URL")
    if server == "":
      server = "https://github.com"
    return normalizeRepo(server.strip(leading = false, chars = {'/'}) & "/" & github)
  return normalizeRepo(getEnv("CI_PROJECT_URL"))

proc hasCharClass*(pattern: string): bool =
  # `[` in a host is an IPv6 literal, which matches as written
  let
    normalized = normalizeRepoPattern(pattern)
    slash      = normalized.find('/')
  return slash != -1 and '[' in normalized[slash + 1 .. ^1]

proc matchesRepo*(entries: seq[(string, string)], repo: string): bool =
  ## `glob` entries as in `golden_images.allowed`, matched against the
  ## normalized repository; other kinds never match
  if repo == "":
    return false
  for (kind, value) in entries:
    if kind != "glob":
      continue
    let normalized = normalizeRepoPattern(value)
    let pattern    = if normalized != "": normalized else: value.strip().toLowerAscii()
    if globMatch(pattern, repo):
      return true
  return false

proc resolveMode*(policy: PolicyConfig, repo: string): PolicyConfig =
  ## Sets the policy's effective mode for `repo` (normalized, empty when
  ## unknown): `mode` where `target_repos` applies the policy, else `off`.
  result = policy
  result.repo          = repo
  result.effectiveMode = policy.mode
  if len(policy.targetRepos) == 0:
    return
  let prefix = if policy.id != "": "policy: " & policy.id & ": " else: "policy: "
  for (kind, value) in policy.targetRepos:
    if kind != "glob":
      warn(prefix & "ignoring target_repos entry of unsupported kind " & kind)
    elif value.hasCharClass():
      warn(prefix & "target_repos entry " & value & " uses `[...]`, which " &
           "globs do not support; `[` only matches itself")
  if repo == "":
    if policy.onUnknownRepo == "apply":
      trace(prefix & "repository could not be determined, on_unknown_repo is apply, " &
            "using mode " & policy.mode)
      return
    let message = prefix & "repository could not be determined, policy not evaluated " &
                  "(on_unknown_repo is skip)"
    if policy.mode == "off": trace(message) else: warn(message)
    result.effectiveMode = "off"
    return
  if not policy.targetRepos.matchesRepo(repo):
    trace(prefix & repo & " is not in target_repos, policy not evaluated")
    result.effectiveMode = "off"
