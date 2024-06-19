##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import std/[base64, strutils, uri]
import ".."/[config, git, util]
import "."/[base]

const
  HEADS          = "refs/heads/"
  TAGS           = "refs/tags/"
  ANNOTATED_TAG  = "^{}"
  GIT_USER       = "x-access-token"
  DEFAULT_BRANCH = "main"

proc setSshKeyscanExeLocation() =
  once:
    sshKeyscanExeLocation = util.findExePath("ssh-keyscan").get("")
    if sshKeyscanExeLocation == "":
      warn("No ssh-keyscan command found in PATH")

proc fetchSshKnownHost(remote: string): string =
  var
    url               = remote
    args: seq[string] = @[]
  if not url.startsWith("ssh://"):
    # uri parser requires schema to be present
    url = "ssh://" & url
  let
    uri  = parseUri(url)
    # ssh root path is delimited by : so we strip it
    # as its not a port number. for example:
    # git@github.com:org/repo.git
    # ssh://git@github.com:22/org/repo.git
    host = uri.hostname.split(":")[0]
  if uri.port != "" and isInt(uri.port):
    args &= @["-p", uri.port]
  args.add(host)
  trace("Running " & sshKeyscanExeLocation & " " & args.join(" "))
  let fetched  = runCmdGetEverything(sshKeyscanExeLocation, args)
  if fetched.exitCode != 0:
    return fetched.stdOut
  return ""

proc createTempKnownHosts(data: string): string =
  if data == "":
    return ""
  let path = writeNewTempFile(data)
  return path

proc isHttpGitContext(context: string): bool =
  if context.startsWith("http://") or context.startsWith("https://"):
    let uri = parseUri(context)
    return uri.path.endsWith(".git")
  return false

proc isSSHGitContext(context: string): bool =
  if context.startsWith("git@"):
    return true
  if context.startsWith("ssh://"):
    let uri = parseUri(context)
    return uri.path.endsWith(".git")
  return false

proc isGitContext*(context: string): bool =
  return isHttpGitContext(context) or isSSHGitContext(context)

proc splitContext(context: string): (string, string, string) =
  let
    (remoteUrl, headSubdir) = context.splitBy("#")
    (head, subdir)          = headSubdir.splitBy(":")
  trace("Docker git context:")
  trace("  remote = " & remoteUrl)
  if head != "":
    trace("    head = " & head)
  if subdir != "":
    trace("  subdir = " & subdir)
  return (remoteUrl, head, subdir)

proc isCommitSha(head: string): bool =
  try:
    return len(head) == 40 and head.parseHexStr() != ""
  except ValueError:
    return false

proc isCheckedOut*(git: DockerGitContext): bool =
  return git.tmpWorkTree != ""

proc contextPath*(git: DockerGitContext): string =
  return joinPath(git.tmpWorkTree, git.subdir).resolvePath()

proc replaceContextArg*(git: DockerGitContext, args: seq[string]): seq[string] =
  if git.isCheckedOut():
    return args.replaceItemWith(git.context, git.contextPath())
  return args

proc run(git:    DockerGitContext,
         args:   seq[string],
         dir:    bool = true,
         strict: bool = true): ExecOutput =
  var
    gitArgs: seq[Redacted] = @[]
    envVars: seq[EnvVar]   = @[]

  if dir:
    gitArgs.add(redact("--git-dir=" & git.tmpGitDir))
    if git.tmpWorkTree != "":
      gitArgs.add(redact("--work-tree=" & git.tmpWorkTree))

  if git.authHeader != "" or git.authToken != "":
    var value = ""
    if git.authToken != "":
      let
        user    = GIT_USER
        token   = git.authToken.strip()
        creds   = user & ":" & token
        encoded = encode(creds)
      value = "basic " & encoded
    else:
      value = git.authHeader
    let
      header = "Authorization: " & value
      option = "http." & git.remoteUrl & ".extraheader="
    gitArgs.add(redact("-c"))
    gitArgs.add(redact(option & header, option & "***"))

  if isSSHGitContext(git.remoteUrl):
    envVars.add(setEnv("GIT_TERMINAL_PROMPT", "0"))
    envVars.add(setEnv("GIT_CONFIG_NOSYSTEM", "1"))
    var sshCmd = "ssh -F /dev/null"
    if git.tmpKnownHost != "":
      sshCmd &= " -o UserKnownHostsFile=" & git.tmpKnownHost
    else:
      sshCmd &= " -o StrictHostKeyChecking=no"
    envVars.add(setEnv("GIT_SSH_COMMAND", sshCmd))

  let allArgs = gitArgs & redact(args)

  trace("Running git " & $(envVars) & allArgs.redacted().join(" "))
  withEnvRestore(envVars):
    # git does not have an option to ignore local .git
    # and therefore will honor its configs
    # therefore the cd here is required so that git operations
    # are isolated in their own directory
    withWorkingDir(git.tmpGitDir):
      result = runCmdGetEverything(getGitExeLocation(), allArgs.raw())
  if strict and result.exitCode != 0:
    error("Failed to run git " & allArgs.redacted().join(" "))
    error(strip(result.stdOut & result.stdErr))
    raise newException(ValueError, "Git failed")

template parseNameFrom(line: string): string =
  if HEADS in line:
    line.split(HEADS)[1].split()[0].strip()
  elif TAGS in line:
    line.split(TAGS)[1].split()[0].strip().removeSuffix(ANNOTATED_TAG)
  else:
    # if the line is parsable use the second item as the refspec
    # otherwise default to complete line
    line.split().getOrDefault(1, line)

template parseCommitFrom(line: string): string =
  line.split()[0]

template parseDefaultBranch(git: DockerGitContext, lines: seq[string]): string =
  if len(lines) > 0 and lines[0].startsWith("ref:"):
    parseNameFrom(lines[0])
  else:
    ""

proc parseCommitForName(name: string, lines: seq[string]): string =
  for line in lines:
    if not line.startsWith("ref:") and parseNameFrom(line) == parseNameFrom(name):
      return parseCommitFrom(line)
  error("Git: there is no git reference for " & name)
  raise newException(ValueError, "Git no commit for reference")

proc parseAllNamesForCommit(commit:     string,
                            lines:      seq[string],
                            refs:       string = "",
                            ignoreRefs: seq[string] = @[]): seq[string] =
  for line in lines:
    if line.startsWith(commit):
      var matched = false
      if refs != "":
        matched = refs in line
      elif len(ignoreRefs) > 0:
        matched = true
        for r in ignoreRefs:
          if r in line:
            matched = false
      if matched:
        let name = parseNameFrom(line)
        if name != "":
          result.add(name)

proc getRemoteHead(git: DockerGitContext, head: string): GitHead =
  # In order for git fetch to be efficient, we do shallow fetch
  # however shallow fetch only fetches specified ref-spec
  # which means if the tag is fetched, its remote/origin/tags/<TAG> ref
  # is fetched however the knowledge about the tag itself is lost on fetch.
  # That can be solved by either:
  # * not doing shallow fetch or
  # * specifying ref-specs during fetch itself such as
  #   git fetch origin <ref> <ref>:refs/tags/<tag>
  # That will fetch the remote ref however will also create appropriate
  # tag reference in local repo all in the same operation.
  # The trick is that the fetch ref-specs need to be specified in fetch
  # args which brings to the purpose of this function.
  # This function parses remote repo ls-remote output to figure out given head's:
  # * commit SHA
  # * branches
  # * tags
  # This information can then be used during fetch to correctly map
  # fetched ref to local refs.
  # As a side bonus, as ls-remote will list all refs, it will ensure
  # that all metadata for the same head will be synced. For example,
  # normally git fetch <tag> will only fetch that one specific tag,
  # regardless if there are other tags pointing to the exact same commit.
  # This function will link all relevant tags which point to the same
  # commit hence allowing fetch to correctly link all tags.
  # Same applies to branches as multiple branches can have the same head.
  let
    output = git.run(@["ls-remote", "--symref", git.remoteUrl], dir = false)
    lines  = output.stdOut.splitLines()
  var head = head
  new result

  if head == "":
    head = git.parseDefaultBranch(lines)
    if head == "":
      error("Git: failed to determine default branch")
      raise newException(ValueError, "Git failed")
    trace("Git: default branch for " & git.remoteUrl & " is " & head)

  if isCommitSha(head):
    result.gitRef    = head
    result.gitType   = GitHeadType.commit
    result.commitId  = head
    result.branches  = parseAllNamesForCommit(result.commitId, lines, HEADS, lines)
    result.tags      = parseAllNamesForCommit(result.commitId, lines, TAGS,  lines)
    result.refs      = parseAllNamesForCommit(result.commitId, lines, ignoreRefs = @[HEADS, TAGS])

  else:
    result.gitRef    = head
    result.commitId  = parseCommitForName(head, lines)
    if result.commitId == "":
      error("Git: failed to find git reference " & head & " in " & git.remoteUrl)
      raise newException(ValueError, "Git failed")
    result.branches  = parseAllNamesForCommit(result.commitId, lines, HEADS)
    result.tags      = parseAllNamesForCommit(result.commitId, lines, TAGS)
    result.refs      = parseAllNamesForCommit(result.commitId, lines, ignoreRefs = @[HEADS, TAGS])
    if head in result.tags:
      result.gitType = GitHeadType.tag
    elif head in result.branches:
      result.gitType = GitHeadType.branch
    else:
      result.gitType = GitHeadType.other

proc init(git: DockerGitContext) =
  discard git.run(@["-c", "init.defaultBranch=" & DEFAULT_BRANCH, "--bare", "init"])
  discard git.run(@["remote", "add", "origin", git.remoteUrl])

proc setGitHEADToCommit(git: DockerGitContext) =
  # there is no git command to detach HEAD to a particular
  # commit so we have to update the file manually.
  # Again very annoying but does not seem to be possible with native CLI.
  # These dont work:
  # * git reset --soft             <- does not change .git/HEAD
  # * git update-ref HEAD <COMMIT> <- updates refs/<HEAD> instead
  # * git symbolic-ref HEAD        <- only supports updating to branches/tags
  discard tryToWriteFile(git.tmpGitDir.joinPath("HEAD"), git.head.commitId)

proc setGitHEADToName(git: DockerGitContext, refs: string) =
  discard git.run(@["symbolic-ref", "HEAD", refs & git.head.gitRef])

proc setGitHEAD(git: DockerGitContext) =
  # as git fetch on bare repos does not update `HEAD`,
  # we need to do that manually as otherwise HEAD will point
  # to the default branch name which is usually `main`
  # even if the pulled ref has nothing to do with `main`.
  # In addition otherwise bare repo is just a collection of loose git refs
  # and it would be hard to parse the current commit/branch/tag
  # which is necessary for git metadata reporting
  case git.head.gitType
    of GitHeadType.commit:
      git.setGitHEADToCommit()
    of GitHeadType.branch:
      git.setGitHEADToName(HEADS)
    of GitHeadType.other:
      git.setGitHeadToname("")
    of GitHeadType.tag:
      # git tags are treated as detached commits on checkout
      git.setGitHEADToCommit()

proc fetch(git: DockerGitContext) =
  var args: seq[string] = @[
    "fetch",
    # bare repo does not seem to update HEAD but we can try
    "--update-head-ok",
    # allow to fetch both a branch or tags
    # and force update if necessary
    "--force",
    # don't fetch all tags from remote
    "--no-tags",
    # shallow fetch for faster operation
    "--depth=1",
    "origin",
    git.head.gitRef,
  ]
  for branch in git.head.branches:
    args.add(branch & ":" & HEADS & branch)
  for tag in git.head.tags:
    args.add(tag & ":" & TAGS & tag)
  for spec in git.head.refs:
    args.add(spec & ":" & spec)
  discard git.run(args)
  git.setGitHead()

proc checkout*(git: DockerGitContext): string =
  git.tmpWorkTree = getNewTempDir(tmpFileSuffix = ".context")
  discard git.run(@["checkout", git.head.gitRef])
  return git.contextPath()

proc show*(git: DockerGitContext, path: string): string =
  let
    root     = git.tmpGitDir
    # path can be relative but git does not support relative paths (e.g. ./)
    # and so we normalize it by using resolvePath() + relativePath()
    fullPath = joinPath(root, git.subdir, path).resolvePath()
    relPath  = fullPath.relativePath(root)
    refSpec  = git.head.gitRef & ":" & relPath
  return git.run(@["show", refSpec]).stdOut

proc gitContext*(context: string,
                 authTokenSecret: DockerSecret,
                 authHeaderSecret: DockerSecret): DockerGitContext =
  setGitExeLocation()

  let (remoteUrl, head, subdir) = splitContext(context)

  new result
  result.context      = context
  result.remoteUrl    = remoteUrl
  result.subdir       = subdir
  result.authToken    = authTokenSecret.getValue()
  result.authHeader   = authHeaderSecret.getValue()
  result.tmpGitDir    = getNewTempDir(tmpFileSuffix = ".git")
  result.tmpKnownHost = ""

  if isSSHGitContext(context):
    setSshKeyscanExeLocation()
    result.tmpKnownHost = createTempKnownHosts(fetchSshKnownHost(remoteUrl))

  result.head = result.getRemoteHead(head)

  result.init()
  result.fetch()
