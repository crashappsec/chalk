## The plugin responsible for pulling metadata from the git
## repository. Leverages the lightweight parsing of the .git directory
## we do in io/gitConfig.nim.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, streams, tables, strutils, strformat
import nimutils, ../types, ../config, ../plugins, ../io/gitConfig

const
  dirGit       = ".git"
  fNameHead    = "HEAD"
  fNameConfig  = "config"
  trVcsDir     = "version control dir: {self.vcsDir}"
  trBranch     = "branch: {self.branchName}"
  trCommit     = "commit ID: {self.commitID}"
  trOrigin     = "origin: {url}"
  wNotParsed   = "{confFileName}: Github configuration file not parsed."
  ghRef        = "ref:"
  ghBranch     = "branch"
  ghRemote     = "remote"
  ghUrl        = "url"
  ghOrigin     = "origin"
  ghLocal      = "local"

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

proc findGitDir(fullpath: string): string =
  let
    (head, tail) = fullpath.splitPath()
    gitdir = head.joinPath(dirGit)

  if tail == "": return
  if gitdir.dirExists(): return gitdir

  return head.findGitDir()

# Using this in the GitRepo plugin too.
type GitPlugin* = ref object of Plugin
  branchName: string
  commitId:   string
  vcsDir*:    string
  origin:     string
  chalkPath:   string

template loadBasics(self: GitPlugin, obj: ChalkObj) =
  self.chalkPath = obj.fullpath
  self.vcsDir = findGitDir(self.chalkPath)
  trace(trVcsDir.fmt())

proc loadHead(self: GitPlugin, obj: ChalkObj): bool =
  # Don't want to commit to the order in which things get called,
  # so everything that might get called first someday calls this to
  # be safe.
  if self.commitID != "":
    return true

  var
    fs: FileStream
    hf: string

  try:
    fs = newFileStream(self.vcsDir.joinPath(fNameHead))
    hf = fs.readAll().strip()

    try:
      fs.close()
    except:
      discard
  except:
    error(fmt"{fNameHead}: github HEAD file couldn't be read")
    return false


  if not hf.startsWith(ghRef):
    self.commitID = hf
    return true

  let
    fname = hf[4 .. ^1].strip()
    parts = if DirSep in fname:
              fname.split(DirSep)
            else:
              fname.split("/")

  if parts.len() < 3:
    error(fmt"{fNameHead}: github HEAD file couldn't be loaded")
    return false

  self.branchName = parts[2 .. ^1].join($DirSep)
  var reffile = newFileStream(self.vcsDir.joinPath(fname))
  self.commitID = reffile.readAll().strip()
  reffile.close()

  trace(trBranch.fmt())
  trace(trCommit.fmt())
  return true

proc calcOrigin(self: GitPlugin, conf: seq[SecInfo]): string =
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
    if sec == ghBranch and subsec == self.branchName:
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

proc getOrigin(self: GitPlugin, obj: ChalkObj): (bool, Box) =
  if not self.loadHead(obj):
    return (false, nil)

  let
    confFileName = self.vcsDir.joinPath(fNameConfig)

  try:
    let
      f = newFileStream(confFileName)
      config = f.parseGitConfig()
      url = self.calcOrigin(config)

    trace(trOrigin.fmt())
    return (true, pack(url))
  except:
    error(wNotParsed.fmt())
    return (false, nil)

# Not sure I'm going to use this.  Stay tuned.
#[
proc getWorkingDir(self: GitPlugin, obj: ChalkObj): (bool, Box) =
  if self.vcsDir != "":
    return (true, pack(self.vcsDir.splitPath().head))
  return (false, nil)
]#

proc getHead(self: GitPlugin, obj: ChalkObj): (bool, Box) =
  if self.commitID == "":
    return (false, nil)
  return (true, pack(self.commitID))

proc getBranch(self: GitPlugin, obj: ChalkObj): (bool, Box) =
  if self.branchName == "":
    return (false, nil)
  return (true, pack(self.branchName))

method getArtifactInfo*(self: GitPlugin, obj: ChalkObj): KeyInfo =
  result = newTable[string, Box]()

  self.loadBasics(obj)

  if self.vcsDir == "":
    return # No git directory, so no work to do.

  let
    (originThere, origin) = self.getOrigin(obj)
    (headThere, head) = self.getHead(obj)
    (branchThere, name) = self.getBranch(obj)

  if originThere: result["ORIGIN_URI"] = origin
  if headThere: result["COMMIT_ID"] = head
  if branchThere: result["BRANCH"] = name


registerPlugin("vctl_git", GitPlugin())
