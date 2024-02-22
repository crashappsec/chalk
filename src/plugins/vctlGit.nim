##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The plugin responsible for pulling metadata from the git
## repository.

import std/[algorithm, nativesockets, sequtils, times]
import pkg/[zippy, zippy/inflate]
import ".."/[config, plugin_api]

const
  eBadGitConf     = "Git configuration file is invalid"
  fanoutTable     = 8
  fanoutSize      = (256 * 4)
  fNameHead       = "HEAD"
  fNameConfig     = "config"
  highBit32       = uint64(0x80000000)
  gpgSignStart    = "-----BEGIN PGP SIGNATURE-----"
  gpgSignEnd      = "-----END PGP SIGNATURE-----"
  ghRef           = "ref:"
  ghBranch        = "branch"
  ghRemote        = "remote"
  ghUrl           = "url"
  ghOrigin        = "origin"
  ghLocal         = "local"
  gitObject       = "object"
  gitAuthor       = "author"
  gitCommitter    = "committer"
  gitCommitMessage = "commitMessage"
  gitTag          = "tag"
  gitSign         = "gpgsig"
  gitTagger       = "tagger"
  gitIdxAll       = "*.idx"
  gitIdxExt       = ".idx"
  gitIdxHeader    = "\xff\x74\x4f\x63\x00\x00\x00\x02"
  gitObjects      = "objects"
  gitPack         = gitObjects.joinPath("pack")
  gitPackExt      = ".pack"
  gitTimeFmt      = "ddd MMM dd HH:mm:ss YYYY"
  gitObjCommit    = 1
  gitHeaderType   = "$type"
  keyVcsDir       = "VCS_DIR_WHEN_CHALKED"
  keyOrigin       = "ORIGIN_URI"
  keyCommit       = "COMMIT_ID"
  keyCommitSigned = "COMMIT_SIGNED"
  keySigned       = "COMMIT_SIGNED"
  keyBranch       = "BRANCH"
  keyAuthor       = "AUTHOR"
  keyAuthorDate   = "DATE_AUTHORED"
  keyCommitter    = "COMMITTER"
  keyCommitDate   = "DATE_COMMITTED"
  keyCommitMessage = "COMMIT_MESSAGE"
  keyLatestTag    = "TAG"
  keyTagSigned    = "TAG_SIGNED"
  keyTagger       = "TAGGER"
  keyTaggedDate   = "DATE_TAGGED"

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
    headExists = fullpath.joinPath(fNameHead).fileExists()
    configExists = fullpath.joinPath(fNameConfig).fileExists()

  # path is probably itself a .git folder such as
  # from git init --bare
  # and so we can return it directly
  if headExists and configExists:
    return fullpath

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
  GitTag = ref object
    name:        string
    commitId:    string
    tagCommitId: string
    tagger:      string
    unixTime:    int
    date:        string
    signed:      bool

  RepoInfo = ref object
    vcsDir:     string
    origin:     string
    branch:     string
    latestTag:  GitTag
    tags:       Table[string, GitTag]
    commitId:   string
    signed:     bool
    author:     string
    authorDate: string
    committer:  string
    commitDate: string
    commitMessage: string

  GitInfo = ref object of RootRef
    branchName: Option[string]
    commitId:   Option[string]
    origin:     Option[string]
    vcsDirs:    OrderedTable[string, RepoInfo]

proc getUint32BE(data: string, whence: SomeInteger=0): uint32 =
  result = ntohl(cast[ptr [uint32]](addr data[whence])[])

template parseTime(line: string): int =
  parseInt(line.split()[^2])

template formatCommitObjectTime(line: string): string =
  fromUnix(parseTime(line)).format(gitTimeFmt) & " " & line.split()[^1]

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
    let data = tryToLoadFile(filename)
    if data == "":
      continue
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
  raise newException(CatchableError, "failed to parse git index")

proc loadObject(info: RepoInfo, refId: string): Table[string, string] =
  let
    objFile     = info.vcsDir.joinPath(gitObjects, refId[0 ..< 2], refId[2 .. ^1])
    objFileData = tryToLoadFile(objFile).strip()

  var objData: string
  try:
    if objFileData != "":
      # if the most recent commit this branch refers to was actually on this
      # branch, we can just read the commit object on the filesystem; the git
      # objects are stored as: .git/objects/01/23456789abcdef<...hash/>
      objData = uncompress(objFileData, dataFormat=dfZlib).strip()
    else:
      # the most recent commit for this branch did not happen on this branch
      # this can happen if users checkout a new branch and haven't committed
      # anything to it yet; we need to unpack this commit from packed objects
      objData = findPackedGitCommit(info.vcsDir, refId).strip()

    let parts = objData.split("\x00", maxsplit = 1)
    if len(parts) == 2:
      result[gitHeaderType] = parts[0].split()[0].strip()
      objData = parts[1].strip()

    let lines = objData.splitLines()
    for l in lines:
      let line = l.strip()
      if line == "":
        break
      let
        parts = line.split(maxsplit = 1)
        key   = parts[0].strip()
        value = parts[1].strip()
      result[key] = value

    # git commits have a field indicating that commit is signed
    # however git tags simply append the gpg signature to the
    # end of the object so we check for that
    # although in theory this can be spoofed by
    # simply including dummy gpg signature in the tag annotation
    # but then signature cant be validated, even by git verify-tag
    if result.getOrDefault(gitHeaderType) == gitTag and
       gpgSignStart in lines and gpgSignEnd in lines and
       objData.endsWith(gpgSignEnd):
      result[gitSign] = ""

    # Set the git commit message.
    # If the commit is signed, the commit message appears after the
    # end of the signature.
    result[gitCommitMessage] = block:
      let iGpgSignEnd = objData.find(gpgSignEnd)
      let iMessageStart =
        if iGpgSignEnd != -1:
          iGpgSignEnd + gpgSignEnd.len
        else:
          objData.find("\n\n")
      objData[iMessageStart ..< objData.len].strip()

  except:
    warn("unable to retrieve Git ref data: " & refId)

proc loadAuthor(info: RepoInfo, commitId: string) =
  let fields = info.loadObject(commitId)
  # this makes only the same assumptions as git itself:
  # https://github.com/git/git/blob/master/commit.c#L97 ddcb8fd
  info.author     = fields.getOrDefault(gitAuthor, "")
  if info.author != "":
    info.authorDate = formatCommitObjectTime(info.author)
  info.committer  = fields.getOrDefault(gitCommitter, "")
  if info.committer != "":
    info.commitDate = formatCommitObjectTime(info.committer)
  info.commitMessage = fields.getOrDefault(gitCommitMessage, "")
  info.signed     = gitSign in fields

proc loadTags(info: RepoInfo, commitId: string) =
  # need commit to compare with
  if commitId == "":
    return

  let tagPath           = info.vcsDir.joinPath("refs", "tags")

  for tag in tagPath.walkDirRec(relative = true):
    let tagCommit = tryToLoadFile(tagPath.joinPath(tag)).strip()
    if tagCommit == "":
      continue
    # regular tag which points directly to the current commit ID
    if tagCommit == commitId:
        trace("tag: " & tag)
        info.tags[tag] = GitTag(name:     tag,
                                commitId: tagCommit)
    # otherwise we need to check where tag points to as the tag can be either:
    # * pointing to another commit
    # * annotated commit object pointing to another commit
    # * annotated commit object pointing to the current commit
    else:
      try:
        let fields = info.loadObject(tagCommit)
        # not an annotated tag
        if fields.getOrDefault(gitHeaderType) != gitTag:
          continue
        # we found annotated commit pointing to current commit
        if fields[gitTag] == tag and fields[gitObject] == info.commitId:
          let
            tagger   = fields[gitTagger]
            unixTime = parseTime(tagger)
            date     = formatCommitObjectTime(tagger)
            signed   = gitSign in fields
          info.tags[tag] = GitTag(name:        tag,
                                  commitId:    fields[gitObject],
                                  tagCommitId: tagCommit,
                                  tagger:      tagger,
                                  unixTime:    unixTime,
                                  date:        date,
                                  signed:      signed)
          trace("annotated tag: " & tag)
      except:
        warn(tag & ": Git tag couldn't be loaded")

  if len(info.tags) > 0:
    let sortedTags = info.tags.values().toSeq().sortedByIt((it.unixTime, it.name))
    info.latestTag = sortedTags[^1]
    trace("latest tag: " & info.latestTag.name)

proc loadCommit(info: RepoInfo, commitId: string) =
  info.commitId = commitId
  trace("commit ID: " & info.commitID)
  info.loadAuthor(commitId)
  info.loadTags(commitId)

proc loadSymref(info: RepoInfo, gitRef: string) =
  let
    fname = gitRef[4 .. ^1].strip()
    parts = fname.split({ DirSep, '/'}, maxsplit = 3)

  if parts.len() < 3:
    error(fNameHead & ": Git HEAD file couldn't be loaded")
    return

  let name = parts[2]
  case parts[1]:
    of "heads":
      info.branch    = name
      trace("branch: " & info.branch)

  let
    fNameRef = info.vcsDir.joinPath(fname)
    commitId = tryToLoadFile(fNameRef).strip()

  if commitId == "":
    warn(fNameRef               &
         ": Git ref file for '" &
         name                   &
         "' doesnt exist. Most likely it's an empty git repo.")
    return

  info.loadCommit(commitId)

proc loadHead(info: RepoInfo) =
  let
    hp = info.vcsDir.joinPath(fNameHead)
    hf = tryToLoadFile(hp).strip()
  if hf == "":
    error(hp & ": Git HEAD file couldn't be read")
    return

  if hf.startsWith(ghRef):
    info.loadSymref(hf)
  else:
    info.loadCommit(hf)

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

proc pack(tag: GitTag): ChalkDict =
  new result
  if tag.tagger != "":
    result[keyTagger] = pack(tag.tagger)
    result[keyTaggedDate] = pack(formatCommitObjectTime(tag.tagger))

proc pack(tags: Table[string, GitTag]): ChalkDict =
  new result
  for name, tag in tags:
    result[name] = pack(tag.pack())

template setVcsKeys(info: RepoInfo) =
  result.setIfNeeded(keyVcsDir,       info.vcsDir.splitPath().head)
  result.setIfNeeded(keyOrigin,       info.origin)
  result.setIfNeeded(keyCommit,       info.commitId)
  result.setIfNeeded(keyCommitSigned, info.signed)
  result.setIfNeeded(keyBranch,       info.branch)
  result.setIfNeeded(keyAuthor,       info.author)
  result.setIfNeeded(keyAuthorDate,   info.authorDate)
  result.setIfNeeded(keyCommitter,    info.committer)
  result.setIfNeeded(keyCommitDate,   info.commitDate)
  result.setIfNeeded(keyCommitMessage, info.commitMessage)

  if info.latestTag != nil:
    result.setIfNeeded(keyLatestTag,  info.latestTag.name)
    result.setIfNeeded(keyTagger,     info.latestTag.tagger)
    result.setIfNeeded(keyTaggedDate, info.latestTag.date)
    result.setIfNeeded(keyTagSigned,  info.latestTag.signed)
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
      info.setVcsKeys()

  for dir, info in cache.vcsDirs:
    if obj.isInRepo(dir):
      info.setVcsKeys()

proc loadVctlGit*() =
  newPlugin("vctl_git",
            ctArtCallback = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
            cache         = RootRef(GitInfo()))
