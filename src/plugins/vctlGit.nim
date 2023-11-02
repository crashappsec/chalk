##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The plugin responsible for pulling metadata from the git
## repository.

import ../config, nativesockets, ../plugin_api, times, zippy, zippy/inflate

const
  eBadGitConf  = "Git configuration file is invalid"
  fanoutTable  = 8
  fanoutSize   = (256 * 4)
  fNameHead    = "HEAD"
  fNameConfig  = "config"
  highBit32    = uint64(0x80000000)
  ghRef        = "ref:"
  ghBranch     = "branch"
  ghRemote     = "remote"
  ghUrl        = "url"
  ghOrigin     = "origin"
  ghLocal      = "local"
  gitAuthor    = "author "
  gitCommitter = "committer "
  gitIdxAll    = "*.idx"
  gitIdxExt    = ".idx"
  gitIdxHeader = "\xff\x7f\x4f\x63\x00\x00\x00\x02"
  gitObjects   = "objects" & DirSep
  gitPack      = gitObjects.joinPath("pack")
  gitPackExt   = ".pack"
  gitTimeFmt   = "ddd MMM dd HH:mm:ss YYYY"
  gitObjCommit = 1
  keyAuthor     = "AUTHOR"
  keyAuthorDate = "DATE_AUTHORED"
  keyCommitter  = "COMMITTER"
  keyCommitDate = "DATE_COMMITTED"

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
    vcsDir:     string
    origin:     string
    branch:     string
    commitId:   string
    author:     string
    authorDate: string
    committer:  string
    commitDate: string

  GitInfo = ref object of RootRef
    branchName: Option[string]
    commitId:   Option[string]
    origin:     Option[string]
    vcsDirs:    OrderedTable[string, RepoInfo]

proc getUint32BE(data: string, whence: SomeInteger=0): uint32 =
  result = ntohl(cast[ptr [uint32]](addr data[whence])[])

proc formatCommitObjectTime(line: string): string =
  let parts = line.split(" ")
  return fromUnix(parseInt(parts[^2])).format(gitTimeFmt) & " " & parts[^1]

proc readPackedCommit(path: string, offset: uint64): string =
  let fileStream = newFileStream(path)
  if fileStream == nil:
    raise(newException(CatchableError, "failed to open " & path))
  fileStream.setPosition(int(offset))
  let initialReadSize = 0x1000
  var
    data = fileStream.readStr(initialReadSize)
    byte = uint8(data[0])
  if ((byte shr 4) and 7) != gitObjCommit:
    raise(newException(CatchableError, "invalid commit object"))
  var
    uncompressedSize = uint64(byte and 0x0F)
    shiftBits        = 4
    currentOffset    = 0
  while (byte and 0x80) != 0:
    currentOffset += 1
    byte = uint8(data[currentOffset])
    uncompressedSize += uint64((byte and 0x7F) shl shiftBits)
    shiftBits += 8
  # My understanding is that we do not have a way to know the compressed size.
  # We assume that either the uncompressed size is bigger than the compressed
  # size, or that a scenario where compressed size is larger would likely only
  # happen with smaller objects (smaller than our initial read size of 0x1000).
  # It seems particularly unlikely with git commit objects, but if these
  # assumptions prove wrong the resulting failure is a signal we report.

  # Given the assumptions above, we attempt to read up to uncompressedSize
  currentOffset += 1
  let remaining = initialReadSize - currentOffset
  if uncompressedSize > uint64(remaining):
    data &= fileStream.readStr(remaining)
  var sourcePointer = cast[ptr UncheckedArray[uint8]](addr data[currentOffset])
  inflate(result, sourcePointer, len(data)-currentOffset, 2)

proc findPackedGitCommit(vcsDir, commitId: string): string =
  let
    nameBytes       = parseHexStr(commitId)
    nameLen         = uint64(len(nameBytes))
    firstByte       = uint8(nameBytes[0])
  var offset: uint64
  for filename in walkFiles(vcsDir.joinPath(gitPack, gitIdxAll)):
    let file = newFileStream(filename)
    if file == nil:
      continue
    let data = file.readAll()
    # Note: this check is both 32bit magic and 32bit version, and they can
    # be split out if a new version comes out, since at that time we would
    # need to revisit this code anyway.
    # Note: we don't support v1 because v2 came out 9+ years ago, and the
    # the repo we are examining would need to have been fetched with a v1
    # version of the git client (even if fetching an old repo, the client
    # only emits v2 .idx and .pack files).
    if data[0 ..< 8] != gitIdxHeader:
      warn("unsupported .idx file " & filename)
      continue
    let
      skipCount  = if firstByte > 0:
                     getUint32BE(data, fanoutTable + (int(firstByte - 1) * 4))
                   else:
                     0
      candidates = getUint32BE(data, fanoutTable + (int(firstByte) * 4)) - skipCount
    if candidates == 0:
      continue
    let
      nameTable   = uint64(fanoutTable + fanoutSize)
      startOffset = nameTable   + (skipCount        * nameLen)
      lastOffset  = startOffset + ((candidates - 1) * nameLen)
    var found     = uint64(0)
    for offset in countUp(startOffset, lastOffset, nameLen):
      let currentNameBytes = data[offset ..< offset + nameLen]
      if currentNameBytes == nameBytes:
        found = offset
      elif uint8(currentNameBytes[0]) != firstByte:
        break
    if found == 0:
      continue
    # nim doesn't currently support division of uint64s
    found = uint64(int((found - nameTable)) / int(nameLen))
    let
      entryCount    = uint64(getUint32BE(data, fanoutTable + (0xFF * 4)))
      tableCrc32    = nameTable     + (entryCount * nameLen)
      tableSize32   = entryCount    * 4
      tableOffset32 = tableCrc32    + tableSize32
      tableOffset64 = tableOffset32 + tableSize32
    offset = uint64(getUint32BE(data, tableOffset32 + (found * 4)))
    if (offset and highBit32) != 0:
      # the offset is actually an index into the next table
      offset = offset xor highBit32
      let high32 = uint64(getUint32BE(data, tableOffset64 + (offset * 8)))
      let low32  = uint64(getUint32BE(data, tableOffset64 + (offset * 8) + 4))
      offset = (high32 shl 32) or low32
    return readPackedCommit(filename.replace(gitIdxExt, gitPackExt), offset)
  raise(newException(CatchableError, "failed to parse git index"))

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
    error(fNameHead & ": Git HEAD file couldn't be read")
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
    error(fNameHead & ": Git HEAD file couldn't be loaded")
    return

  info.branch   = parts[2 .. ^1].join($DirSep)
  trace("branch: " & info.branch)

  let
    fNameRef = info.vcsDir.joinPath(fname)
    reffile  = newFileStream(fNameRef)
  if reffile != nil:
    info.commitId = reffile.readAll().strip()
    reffile.close()
    trace("commit ID: " & info.commitID)
    let
      commitId = info.commitId
      objPath  = gitObjects.joinPath(commitId[0 ..< 2], commitId[2 .. ^1])
      objFile  = newFileStream(info.vcsDir.joinPath(objPath))
    var objData: string
    try:
      if objFile != nil:
        # if the most recent commit this branch refers to was actually on this
        # branch, we can just read the commit object on the filesystem; the git
        # objects are stored as: .git/objects/01/23456789abcdef<...hash/>
        objData = uncompress(objFile.readAll(), dataFormat=dfZlib)
      else:
        # the most recent commit for this branch did not happen on this branch
        # this can happen if users checkout a new branch and haven't committed
        # anything to it yet; we need to unpack this commit from packed objects
        objData = findPackedGitCommit(info.vcsDir, commitId)
      let lines = objData.split("\n")
      for index, line in lines:
        if line.startsWith(gitAuthor):
          # this makes only the same assumptions as git itself:
          # https://github.com/git/git/blob/master/commit.c#L97 ddcb8fd
          # only in a Nim try/except block so we don't explicitly check bounds
          info.author     = line[len(gitAuthor) .. ^1]
          info.authorDate = formatCommitObjectTime(line)
          info.committer  = lines[index + 1][len(gitCommitter) .. ^1]
          info.commitDate = formatCommitObjectTime(lines[index + 1])
          break
    except:
      warn("unable to retrieve Git commit data: " & commitId)
  else:
    warn(fNameRef                      &
         ": Git ref file for branch '" &
         info.branch                   &
         "' doesnt exist. Most likely it's an empty git repo.")

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
    error(confFileName & ": Git configuration file not parsed.")
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
  if info.author != "":
    result[keyAuthor] = pack(info.author)
  if info.authorDate != "":
    result[keyAuthorDate] = pack(info.authorDate)
  if info.committer != "":
    result[keyCommitter] = pack(info.committer)
  if info.commitDate != "":
    result[keyCommitDate] = pack(info.commitDate)
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
            ctArtCallback = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
            cache         = RootRef(GitInfo()))
