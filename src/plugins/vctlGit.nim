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
import ".."/[config, git, plugin_api, util]

const
  eBadGitConf      = "Git configuration file is invalid"
  fanoutTable      = 8
  fanoutSize       = (256 * 4)
  fNameHead        = "HEAD"
  fNameConfig      = "config"
  highBit32        = uint64(0x80000000)
  gpgSignStart     = "-----BEGIN PGP SIGNATURE-----"
  gpgSignEnd       = "-----END PGP SIGNATURE-----"
  ghRef            = "ref:"
  ghBranch         = "branch"
  ghRemote         = "remote"
  ghUrl            = "url"
  ghOrigin         = "origin"
  ghLocal          = "local"
  gitObject        = "object"
  gitAuthor        = "author"
  gitCommitter     = "committer"
  gitMessage       = "message" ## Either a commit message or a tag message.
  gitCommit        = "commit"
  gitTag           = "tag"
  gitSign          = "gpgsig"
  gitTagger        = "tagger"
  gitIdxAll        = "*.idx"
  gitIdxExt        = ".idx"
  gitIdxHeader     = "\xff\x74\x4f\x63\x00\x00\x00\x02"
  gitObjects       = "objects"
  gitPackRefs      = "packed-refs"
  gitPack          = gitObjects.joinPath("pack")
  gitPackExt       = ".pack"
  gitTimeFmt       = "ddd MMM dd HH:mm:ss YYYY"
  # https://git-scm.com/docs/pack-format
  gitObjCommit     = 1
  gitObjTag        = 4
  gitHeaderType    = "$type"
  keyVcsDir        = "VCS_DIR_WHEN_CHALKED"
  keyOrigin        = "ORIGIN_URI"
  keyCommit        = "COMMIT_ID"
  keyCommitSigned  = "COMMIT_SIGNED"
  keyBranch        = "BRANCH"
  keyAuthor        = "AUTHOR"
  keyAuthorDate    = "DATE_AUTHORED"
  keyCommitter     = "COMMITTER"
  keyCommitDate    = "DATE_COMMITTED"
  keyCommitMessage = "COMMIT_MESSAGE"
  keyLatestTag     = "TAG"
  keyTagSigned     = "TAG_SIGNED"
  keyTagger        = "TAGGER"
  keyTaggedDate    = "DATE_TAGGED"
  keyTagMessage    = "TAG_MESSAGE"

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
    message:     string

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
    message:    string

  GitInfo = ref object of RootRef
    branchName: Option[string]
    commitId:   Option[string]
    origin:     Option[string]
    vcsDirs:    OrderedTable[string, RepoInfo]

proc isAnnotated(self: GitTag): bool =
  return self.tagCommitId != ""

proc getUint32BE(data: string, whence: SomeInteger=0): uint32 =
  result = ntohl(cast[ptr [uint32]](addr data[whence])[])

template parseTime(line: string): int =
  parseInt(line.split()[^2])

template formatCommitObjectTime(line: string): string =
  fromUnix(parseTime(line)).format(gitTimeFmt) & " " & line.split()[^1]

proc readPackedObject(path: string, offset: uint64): string =
  ## read packaged git object
  ## supports reading git commit and tag objects
  ## https://git-scm.com/docs/pack-format
  ## https://git-scm.com/book/en/v2/Git-Internals-Packfiles
  withFileStream(path, mode = fmRead, strict = true):
    stream.setPosition(int(offset))
    let initialReadSize = 0x1000
    var
      data    = stream.readStr(initialReadSize)
      byte    = uint8(data[0])
      objType = ((byte shr 4) and 7)
      gitType =
        case objType
        of gitObjCommit:
          gitCommit
        of gitObjTag:
          gitTag
        else:
          raise newException(ValueError, "not a commit or tag object - unsupported git object type: " & $objType)
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
    # It seems particularly unlikely with git objects, but if these
    # assumptions prove wrong the resulting failure is a signal we report.

    # Given the assumptions above, we attempt to read up to uncompressedSize
    currentOffset += 1
    let remaining = initialReadSize - currentOffset
    if uncompressedSize > uint64(remaining):
      data &= stream.readStr(remaining)
    var
      sourcePointer    = cast[ptr UncheckedArray[uint8]](addr data[currentOffset])
      uncompressedData = ""
    inflate(uncompressedData, sourcePointer, len(data)-currentOffset, 2)
    # add back object header to match individual object files
    # for consistent parsing
    let objectHeader = gitType & " " & $uncompressedSize & "\x00"
    return objectHeader & uncompressedData

proc findPackedGitObject(vcsDir, refId: string): string =
  ## https://git-scm.com/docs/pack-format
  ## https://git-scm.com/book/en/v2/Git-Internals-Packfiles
  let
    nameBytes       = parseHexStr(refId)
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
    return readPackedObject(filename.replace(gitIdxExt, gitPackExt), offset)
  raise newException(CatchableError, "failed to parse git index")

proc isTag(self: Table[string, string]): bool =
  let gitType = self.getOrDefault(gitHeaderType)
  return (
    gitType   == gitTag and
    gitTag    in self   and
    gitObject in self
  )

proc loadObject(info: RepoInfo, refId: string): Table[string, string] =
  ## https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
  let
    objFile     = info.vcsDir.joinPath(gitObjects, refId[0 ..< 2], refId[2 .. ^1])
    objFileData = tryToLoadFile(objFile)

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
      objData = findPackedGitObject(info.vcsDir, refId).strip()

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
    if result.isTag() and
       gpgSignStart in lines and
       gpgSignEnd   in lines and
       objData.endsWith(gpgSignEnd):
      result[gitSign] = ""

    # Get the git commit message or tag message.
    # If the object is a signed tag, the tag message appears before the start of
    # the signature.
    # If the object is a signed commit, the commit message appears after the
    # end of the signature.
    block:
      let iMessageStart =
        if result.getOrDefault(gitHeaderType) == gitTag:
          objData.find("\n\n")
        else:
          let iGpgSignEnd = objData.find(gpgSignEnd)
          if iGpgSignEnd != -1:
            iGpgSignEnd + gpgSignEnd.len
          else:
            objData.find("\n\n")
      let iMessageEnd =
        if result.getOrDefault(gitHeaderType) == gitTag:
          let iGpgSignStart = objData.find(gpgSignStart)
          if iGpgSignStart != -1:
            iGpgSignStart
          else:
            objData.len
        else:
          objData.len
      if iMessageStart > 0 and iMessageEnd > 0 and iMessageStart <= iMessageEnd:
        result[gitMessage] = objData[iMessageStart ..< iMessageEnd].strip()

  except:
    warn("unable to retrieve Git ref data: " & refId & " due to: " & getCurrentExceptionMsg())

proc getAllPackedRefs(info: RepoInfo): Table[string, string] =
  result = initTable[string, string]()
  let
    path = info.vcsDir.joinPath(gitPackRefs)
    refs = tryToLoadFile(path).strip()
  if refs == "":
    return
  for line in refs.splitLines():
    # format is <sha> <ref>
    if "refs/" notin line:
      continue
    let parts = line.split()
    if len(parts) != 2:
      continue
    result[parts[1]] = parts[0]

proc loadRef(info: RepoInfo, gitRef: string): string =
  let
    path  = info.vcsDir.joinPath(gitRef)
    objId = tryToLoadFile(path).strip()
  if objId != "":
    result = objId
  else:
    result = info.getAllPackedRefs().getOrDefault(gitRef)
  if result == "":
    return
  if gitRef.startsWith("refs/tags"):
    let fields = info.loadObject(result)
    if fields.isTag():
      let commitId = fields[gitObject]
      trace("git object for " & gitRef & ": " & result & " which points to commit: " & commitId)
      result = commitId

proc loadAuthor(info: RepoInfo) =
  let fields = info.loadObject(info.commitId)
  # this makes only the same assumptions as git itself:
  # https://github.com/git/git/blob/master/commit.c#L97 ddcb8fd
  info.author     = fields.getOrDefault(gitAuthor, "")
  if info.author != "":
    info.authorDate = formatCommitObjectTime(info.author)
  info.committer  = fields.getOrDefault(gitCommitter, "")
  if info.committer != "":
    info.commitDate = formatCommitObjectTime(info.committer)
  info.message    = fields.getOrDefault(gitMessage, "")
  info.signed     = gitSign in fields

proc loadTag(info: RepoInfo, tag: string, tagCommit: string) =
  # lightweight tag which points directly to the current commit ID
  if tagCommit == info.commitId:
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
      if not fields.isTag():
        return
      # we found annotated commit pointing to current commit
      if fields[gitTag] == tag and fields[gitObject] == info.commitId:
        let
          tagger   = fields[gitTagger]
          unixTime = parseTime(tagger)
          date     = formatCommitObjectTime(tagger)
          signed   = gitSign in fields
          message  = fields.getOrDefault(gitMessage)
        info.tags[tag] = GitTag(name:        tag,
                                commitId:    fields[gitObject],
                                tagCommitId: tagCommit,
                                tagger:      tagger,
                                unixTime:    unixTime,
                                date:        date,
                                signed:      signed,
                                message:     message)
        trace("annotated tag: " & tag)
    except:
      warn(tag & ": Git tag couldn't be loaded - " & getCurrentExceptionMsg())

proc loadAllTags(info: RepoInfo): Table[string, string] =
  result = initTable[string, string]()
  for gitRef, objId in info.getAllPackedRefs():
    if not gitRef.startsWith("refs/tags/"):
      continue
    let parts = gitRef.split("/", maxsplit = 2)
    result[parts[2]] = objId
  let tagPath = info.vcsDir.joinPath("refs", "tags")
  for tag in tagPath.walkDirRec(relative = true):
    let tagCommit = tryToLoadFile(tagPath.joinPath(tag)).strip()
    if tagCommit != "":
      result[tag] = tagCommit

proc loadTags(info: RepoInfo) =
  # need commit to compare with
  if info.commitId == "":
    return

  info.tags = initTable[string, GitTag]()
  for tag, tagCommit in info.loadAllTags():
    info.loadTag(tag       = tag,
                 tagCommit = tagCommit)

  if len(info.tags) > 0:
    let sortedTags = info.tags.values().toSeq().sortedByIt((it.unixTime, it.name))
    info.latestTag = sortedTags[^1]
    trace("latest tag: " & info.latestTag.name)

proc refetchTags(info: RepoInfo) =
  if info.origin == "" or info.origin == ghLocal:
    return
  if not attrGet[bool]("git.refetch_lightweight_tags"):
    return
  var toRefetch: seq[GitTag] = @[]
  for _, tag in info.tags:
    if not tag.isAnnotated():
      toRefetch.add(tag)
  if len(toRefetch) == 0:
    return
  let exe = getGitExeLocation()
  if exe == "":
    return
  var args = @[
    "fetch",
    info.origin,
    "--force",                 # allow to update the tag
    "--no-tags",               # dont fetch everything
    "--no-recurse-submodules", # ignore submodules
    "--depth=1",               # faster fetch
    info.commitId,
  ]
  for tag in toRefetch:
    args.add(tag.name & ":refs/tags/" & tag.name)
  trace("git " & args.join(" "))
  let output = runCmdGetEverything(getGitExeLocation(), args)
  if output.getExit() != 0:
    trace("git: could not fetch latest tag from origin: " & output.getStdErr())
    return
  let oldLatestTag = info.latestTag
  info.loadTags()
  if oldLatestTag.tagCommitId != info.latestTag.tagCommitId:
    info("git: origin fetch updated tag (" & info.latestTag.name & ") from " &
         "lightweight tag to annotated tag. Its object id changed from commit " &
         oldLatestTag.commitId & " to tag commit " & info.latestTag.tagCommitId)

proc loadCommit(info: RepoInfo, commitId: string) =
  info.commitId = commitId
  trace("commit ID: " & info.commitID)
  info.loadAuthor()
  info.loadTags()

proc loadSymref(info: RepoInfo, gitRef: string) =
  let
    fname = gitRef[4 .. ^1].strip()
    parts = fname.split({ DirSep, '/' }, maxsplit = 2)

  if parts.len() < 3:
    error(fNameHead & ": Git HEAD file couldn't be loaded")
    return

  let name = parts[2]
  case parts[1]:
    of "heads":
      info.branch = name
      trace("branch: " & info.branch)
    of "tags":
      trace("tag: " & name)

  let commitId = info.loadRef(fname)
  if commitId == "":
    warn(gitRef & ": Git ref file for '" & name & "' doesnt exist. " &
         "Most likely it's an empty git repo.")
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

  trace("Found version control dir: " & vcsDir)
  info.loadHead()
  if info.commitId == "":
    return

  withFileStream(confFileName, mode = fmRead, strict = false):
    try:
      if stream != nil:
        let config = stream.parseGitConfig()
        info.origin = info.calcOrigin(config)
        info.refetchTags()
    except:
      error(confFileName & ": Git configuration file not parsed: " & getCurrentExceptionMsg())
      dumpExOnDebug()

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

proc setVcsKeys(chalkDict: ChalkDict, info: RepoInfo, prefix = "") =
  if prefix == "":
    chalkDict.setIfNeeded(prefix & keyVcsDir,      info.vcsDir.splitPath().head)

  chalkDict.setIfNeeded(prefix & keyOrigin,        info.origin)
  chalkDict.setIfNeeded(prefix & keyCommit,        info.commitId)
  chalkDict.setIfNeeded(prefix & keyCommitSigned,  info.signed)
  chalkDict.setIfNeeded(prefix & keyBranch,        info.branch)
  chalkDict.setIfNeeded(prefix & keyAuthor,        info.author)
  chalkDict.setIfNeeded(prefix & keyAuthorDate,    info.authorDate)
  chalkDict.setIfNeeded(prefix & keyCommitter,     info.committer)
  chalkDict.setIfNeeded(prefix & keyCommitDate,    info.commitDate)
  chalkDict.setIfNeeded(prefix & keyCommitMessage, info.message)

  if info.latestTag != nil:
    chalkDict.setIfNeeded(prefix & keyLatestTag,   info.latestTag.name)
    chalkDict.setIfNeeded(prefix & keyTagger,      info.latestTag.tagger)
    chalkDict.setIfNeeded(prefix & keyTaggedDate,  info.latestTag.date)
    chalkDict.setIfNeeded(prefix & keyTagSigned,   info.latestTag.signed)
    chalkDict.setIfNeeded(prefix & keyTagMessage,  info.latestTag.message)

proc isInRepo(obj: ChalkObj, repo: string): bool =
  if obj.fsRef == "":
    return false

  let prefix = repo.splitPath().head
  if obj.fsref.resolvePath().startsWith(prefix):
    return true

  return false

proc gitInit(self: Plugin): Plugin =
  once:
    let cache = GitInfo(self.internalState)
    for path in getContextDirectories():
      cache.findAndLoad(path.resolvePath())
  return self

proc gitFirstDir*(self: Plugin): string =
  discard self.gitInit()
  let cache = GitInfo(self.internalState)
  for dir, _ in cache.vcsDirs:
    return dir
  raise newException(ValueError, "no git folder in any of the contexts")

proc gitGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                ChalkDict {.cdecl.} =
  discard self.gitInit()

  result    = ChalkDict()
  let cache = GitInfo(self.internalState)

  if len(cache.vcsDirs) == 0:
    return

  if obj.fsRef == "":
    for dir, info in cache.vcsDirs:
      result.setVcsKeys(info)
      break

  for dir, info in cache.vcsDirs:
    if obj.isInRepo(dir):
      result.setVcsKeys(info)
      break

proc gitGetRunTimeHostInfo(self: Plugin, chalks: seq[ChalkObj]):
                           ChalkDict {.cdecl.} =
  discard self.gitInit()

  result = ChalkDict()
  let cache = GitInfo(self.internalState)
  for dir, info in cache.vcsDirs:
    result.setVcsKeys(info, prefix = "_")
    break

proc loadVctlGit*() =
  newPlugin("vctl_git",
            ctArtCallback  = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
            rtHostCallback = RunTimeHostCb(gitGetRunTimeHostInfo),
            cache          = RootRef(GitInfo()))
