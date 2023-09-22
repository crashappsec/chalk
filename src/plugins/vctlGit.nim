##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The plugin responsible for pulling metadata from the git
## repository.

import ../config, ../plugin_api

const
  fNameHead    = "HEAD"
  fNameConfig  = "config"
  ghRef        = "ref:"
  ghBranch     = "branch"
  ghRemote     = "remote"
  ghUrl        = "url"
  ghOrigin     = "origin"
  ghLocal      = "local"
  eBadGitConf  = "Github configuration file is invalid"

type
  KVPair*  = (string, string)
  KVPairs* = seq[KVPair]
  SecInfo* = (string, string, KVPairs)

proc ws(s: Stream) =
  while true:
    if s.peekChar() in[' ', '\t']: discard s.readChar()
    else: return

proc newLine(s: Stream) =
  if s.readChar() != '\n': raise newException(ValueError, eBadGitConf)

proc comment(s: Stream) =
  while s.readChar() notin ['\n', '\x00']: discard

# Comments aren't allowed in between the brackets
proc header(s: Stream): (string, string) =
  var sec: string
  var sub: string

  while true:
    let c = s.readChar()
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.': sec = sec & $c
    of ' ', '\t':
      s.ws()
      let c = s.readChar()
      case c
      of ']': return (sec, sub)
      of '"':
        while true:
          let c = s.readChar()
          case c
          of '\\': sub = sub & $(s.readChar())
          of '"': break
          of '\x00': raise newException(ValueError, eBadGitConf)
          else:
            sub = sub & $c
      else: raise newException(ValueError, eBadGitConf)
    of ']': return (sec, sub)
    else: raise newException(ValueError, eBadGitConf)

proc kvPair(s: Stream): KVPair =
  var
    key: string
    val: string

  s.ws()
  while true:
    let c = s.peekChar()
    case c
    of '#', ';':
      discard s.readChar()
      s.comment()
      if key == "": return ("", "")
    of 'a'..'z', 'A'..'Z', '0'..'9', '-': key = key & $s.readChar()
    of ' ', '\t':
      discard s.readChar()
      s.ws()
    of '=':
      discard s.readChar()
      break
    of '\n', '\x00':
      discard s.readChar()
      return (key, "")
    of '\\':
      discard s.readChar()
      if s.readChar() != '\n':
        raise newException(ValueError, eBadGitConf)
      s.ws()
    else: raise newException(ValueError, eBadGitConf)

  s.ws()

  while true:
    var inString = false
    let c = s.readChar()
    case c
    of '\n', '\x00': break
    of '#', ';':
      if not inString:
        s.comment()
        break
      else:
        val = val & $c
    of '\\':
      let n = s.readChar()
      case n
      of '\n':
        continue
      of '\\', '"': val = val & $n
      of 'n':       val = val & "\n"
      of 't':       val = val & "\t"
      of 'b':       val = val & "\b"
      else:         val = val & $n        # Be permissive, have a heart!
    of '"': inString = not inString
    else:   val = val & $c

  return (key, val)

proc kvpairs(s: Stream): KVPairs =
  result = @[]

  while true:
    s.ws()
    case s.peekChar()
    of '\x00', '[': return
    of '\n':
      s.newLine()
      continue
    else: discard
    try:
      let (k, v) = s.kvPair()
      if k != "": result.add((k, v))
    except: discard # Should we warn instead of ignroing?

proc section(s: Stream): SecInfo =
  var sec, sub: string

  while true:
    s.ws()
    let c = s.readChar()
    case c
    of '#', ';': s.comment()
    of ' ', '\t', '\n': continue
    of '[':
      s.ws()
      (sec, sub) = s.header()
      s.ws()
      s.newLine()
      return (sec, sub, s.kvPairs())
    of '\x00': return ("", "", @[])
    else:      raise newException(ValueError, eBadGitConf)

# TODO: This doesn't handle the include.path mechanism yet
# TODO: Some more grace on parse errors.
#
# This doesn't actually parse ints or bool, just returns
# everything as strings.
#
# config: section*
# section: header '\n' kvpair*
# header: '[' string subsection? ']'
# subsection: ([ \t]+ '"' string '"'
# kvpair: name [ \t]+ ([\\n']?('=' string)?)*
# name: [a-zA-Z0-9-]+
# # and ; are comments.
proc parseGitConfig(s: Stream): seq[SecInfo] =
  while true:
    let (sec, sub, pairs) = s.section()
    if sec == "": return
    else:         result.add((sec, sub, pairs))

proc findGitDir(fullpath: string): string =
  let
    gitDir       = fullpath.joinPath(".git")
    (head, tail) = fullpath.splitPath()

  if gitdir.dirExists():
    return gitDir

  if tail == "":
    return

  return head.findGitDir()

# Using this in the GitRepo plugin too.
type
  RepoInfo = ref object
    vcsDir:   string
    origin:   string
    branch:   string
    commitId: string

  GitInfo = ref object of RootRef
    branchName: Option[string]
    commitId:   Option[string]
    origin:     Option[string]
    vcsDirs:    OrderedTable[string, RepoInfo]

proc loadHead(info: RepoInfo) =
  var
    fs: FileStream
    hf: string

  try:
    fs = newFileStream(info.vcsDir.joinPath(fNameHead))
    if fs != nil:
      hf = fs.readAll().strip()
    else:
      return

    try:
      fs.close()
    except:
      discard
  except:
    error(fNameHead & ": github HEAD file couldn't be read")
    dumpExOnDebug()
    return

  if not hf.startsWith(ghRef):
    info.commitId = hf
    return

  let
    fname = hf[4 .. ^1].strip()
    parts = if DirSep in fname:
              fname.split(DirSep)
            else:
              fname.split("/")

  if parts.len() < 3:
    error(fNameHead & ": github HEAD file couldn't be loaded")
    return

  info.branch   = parts[2 .. ^1].join($DirSep)
  var reffile   = newFileStream(info.vcsDir.joinPath(fname))
  info.commitId = reffile.readAll().strip()
  reffile.close()

  trace("branch: " & info.branch)
  trace("commit ID: " & info.commitID)

proc calcOrigin(self: RepoInfo, conf: seq[SecInfo]): string =
  # We are generally looking for the remote origin, because we expect
  # this is running from a checked-out copy of a repo.  It's
  # possible there could be multiple remotes, each associated with multiple
  # branches. So what we do is:
  #
  # 1. Look for the subsection for our branch, then for the "remote"
  #    variable. If it's not there, skip to step 3.
  #
  # 2. Try to find the remote section with the sub-section that matches
  #    our branch's remote field, and return the URL field.  If there's
  #    no such section or no url variable, hit step 3 instead.
  #
  # 3. If there's a [remote "origin"] section w/ a URL field, return that.
  #
  # 4. If there's ANY remote section w/ a URL, return the first one
  #    that has a URL.
  #
  # 5. Return the word "local"
  for (sec, subsec, kvpairs) in conf:
    if sec == ghBranch and subsec == self.branch:
      for (k, v) in kvpairs:
        if k == ghRemote:
          for (sec, subsec, kvpairs) in conf:
            if sec == ghRemote and subsec == v:
              for (k, v) in kvpairs:
                if k == ghUrl:
                  self.origin = v
                  return v

  var firstFound: string
  for (sec, subsec, kvpairs) in conf:
    if sec == ghRemote:
      if subsec == ghOrigin:
        for (k, v) in kvpairs:
          if k == ghUrl:
            self.origin = v
            return v
      elif firstFound == "":
        for (k, v) in kvpairs:
          if k == ghUrl:
            firstFound = v
            break
  if firstFound != "":
    self.origin = firstFound
    return firstFound

  self.origin = ghLocal
  return ghLocal


proc findAndLoad(plugin: GitInfo, path: string) =
  trace("Looking for .git directory, from: " & path)
  let vcsDir = path.findGitDir()

  if vcsDir == "" or vcsDir in plugin.vcsDirs:
    return

  let
    confFileName = vcsDir.joinPath(fNameConfig)
    info         = RepoInfo(vcsDir: vcsDir)
    f            = newFileStream(confFileName)
  trace("Found version control dir: " & vcsDir)
  info.loadHead()

  try:
    if f != nil:
      let config = f.parseGitConfig()
      info.origin = info.calcOrigin(config)
  except:
    error(confFileName & ": Github configuration file not parsed.")
    dumpExOnDebug()

  if info.commitId == "":
    return

  plugin.vcsDirs[vcsDir] = info

template setVcsStuff(info: RepoInfo) =
  result["VCS_DIR_WHEN_CHALKED"] = pack(info.vcsDir.splitPath().head)
  if info.origin != "":
    result["ORIGIN_URI"] = pack(info.origin)
  if info.commitId != "":
    result["COMMIT_ID"] = pack(info.commitId)
  if info.branch != "":
    result["BRANCH"] = pack(info.branch)
  break

proc isInRepo(obj: ChalkObj, repo: string): bool =
  if obj.fsRef == "":
    return false

  let prefix = repo.splitPath().head
  if obj.fsref.resolvePath().startsWith(prefix):
    return true

  return false

proc gitInit(self: Plugin) =
  let cache = GitInfo(self.internalState)

  for path in getContextDirectories():
    cache.findAndLoad(path.resolvePath())

proc gitGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                ChalkDict {.cdecl.} =
  once:
    self.gitInit()

  result    = ChalkDict()
  let cache = GitInfo(self.internalState)

  if len(cache.vcsDirs) == 0:
    return

  if obj.fsRef == "":
    for dir, info in cache.vcsDirs:
      info.setVcsStuff()

  for dir, info in cache.vcsDirs:
    if obj.isInRepo(dir):
      info.setVcsStuff()

proc loadVctlGit*() =
  newPlugin("vctl_git",
            ctArtCallback  = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
            cache          =  RootRef(GitInfo()))
