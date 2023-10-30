##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import base64, strutils, uri
import config, util, docker_base

proc setGitExeLocation() =
  once:
    trace("Searching path for 'git'")
    var
      userPath: seq[string]
      exeOpt   = chalkConfig.getGitExe()

    if exeOpt.isSome():
      # prepend on purpose so that git_exe config
      # takes precedence over rest of dirs in PATH
      userPath = @[exeOpt.get()] & userPath

    gitExeLocation = findExePath("git", userPath).get()

    if gitExeLocation == "":
       error("No git command found in PATH")

proc isGitContext*(context: string): bool =
  if context.startsWith("http://") or context.startsWith("https://"):
    let uri = parseUri(context)
    return uri.path.endsWith(".git")
  return context.startswith("git@")

proc splitBy(s: string, sep: string, default: string = ""): (string, string) =
  let parts = s.split(sep, maxsplit = 1)
  if len(parts) == 2:
    return (parts[0], parts[1])
  return (s, default)

proc splitContext(context: string): (string, string, string) =
  let
    (remoteUrl, headSubdir) = context.splitBy("#")
    (head, subdir) = headSubdir.splitBy(":")
  trace("Docker git context:")
  trace("remote = " & remoteUrl)
  trace("  head = " & head)
  if len(subdir) > 0:
    trace("subdir = " & subdir)
  return (remoteUrl, head, subdir)

proc isCommitSha(head: string): bool =
  try:
    return len(head) == 40 and head.parseHexInt() > 0
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

proc run(git: DockerGitContext,
         args: seq[string],
         dir: bool = true,
         strict: bool = true): ExecOutput =
  var gitArgs: seq[Redacted] = @[]

  if dir:
    gitArgs.add(redact("--git-dir=" & git.tmpGitDir))
    if git.tmpWorkTree != "":
      gitArgs.add(redact("--work-tree=" & git.tmpWorkTree))

  if git.authHeader != "" or git.authToken != "":
    var value = ""
    if git.authToken != "":
      let
        user  = "x-access-token"
        token = git.authToken.strip()
        creds = user & ":" & token
        encoded = encode(creds)
      value = "basic " & encoded
    else:
      value = git.authHeader
    let
      header = "Authorization: " & value
      option = "http." & git.remoteUrl & ".extraheader="
    gitArgs.add(redact("-c"))
    gitArgs.add(redact(option & header, option & "***"))

  let allArgs = gitArgs & redact(args)

  trace("Running git " & allArgs.redacted().join(" "))
  result = runCmdGetEverything(gitExeLocation, allArgs.raw())
  if strict and result.exitCode != 0:
    error("Failed to run git " & allArgs.redacted().join(" "))
    error(strip(result.stdOut & result.stdErr))
    raise newException(ValueError, "Git failed")

proc getDefaultBranch(git: DockerGitContext): string =
  let output = git.run(@["ls-remote", "--symref", git.remoteUrl, "HEAD"], dir = false)
  for line in output.stdOut.splitLines():
    if "refs/heads/" in line:
      return line.split("refs/heads/")[1].split()[0].strip()

proc init(git: DockerGitContext) =
  discard git.run(@["-c", "init.defaultBranch=main", "--bare", "init"])
  discard git.run(@["remote", "add", "origin", git.remoteUrl])

proc fetch(git: DockerGitContext) =
  var args: seq[string] = @["fetch"]
  if not isCommitSha(git.head):
    args.add("--depth=1")
    args.add("--no-tags")
    # allow to fetch both a branch or tags
    # and force update if necessary
    args.add("--force")
  args.add("origin")
  if isCommitSha(git.head):
    args.add(git.head)
  else:
    args.add(git.head & ":tags/" & git.head)
  discard git.run(args)

proc checkout*(git: DockerGitContext): string =
  git.tmpWorkTree = getNewTempDir(tmpFileSuffix = ".context")
  discard git.run(@["checkout", git.head])
  return git.contextPath()

proc show*(git: DockerGitContext, path: string): string =
  let
    root     = git.tmpGitDir
    # path can be relative but git does not support relative paths (e.g. ./)
    # and so we normalize it by using resolvePath() + relativePath()
    fullPath = joinPath(root, git.subdir, path).resolvePath()
    relPath  = fullPath.relativePath(root)
    refSpec  = git.head & ":" & relPath
  return git.run(@["show", refSpec]).stdOut

proc gitContext*(context: string,
                 authTokenSecret: DockerSecret,
                 authHeaderSecret: DockerSecret): DockerGitContext =
  setGitExeLocation()
  if gitExeLocation == "":
    raise newException(ValueError, "No git")

  let (remoteUrl, head, subdir) = splitContext(context)

  new result
  result.context     = context
  result.remoteUrl   = remoteUrl
  result.head        = head
  result.subdir      = subdir
  result.authToken   = authTokenSecret.getValue()
  result.authHeader  = authHeaderSecret.getValue()
  result.tmpGitDir   = getNewTempDir(tmpFileSuffix = ".git")

  if result.head == "":
    result.head = result.getDefaultBranch()

  result.init()
  result.fetch()
