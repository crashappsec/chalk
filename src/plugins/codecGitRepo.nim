import os, tables, nimutils, streams, ../config, ../plugins, vctlGit

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type CodecGitRepo* = ref object of Codec

var cache: Table[string, KeyInfo] = initTable[string, KeyInfo]()

method scan*(self: CodecGitRepo, sami: SamiObj): bool =
  # Never interfere with a self-SAMI.  Leave that to the real codecs.
  if sami.fullpath == resolvePath(getAppFileName()):
    return false

  var
    gitCtx = GitPlugin()
    info   = gitCtx.getArtifactInfo(sami)

  if len(info) == 0:
    return false

  let
    gitpath  = gitCtx.vcsDir
    path     = gitpath.splitPath().head

  if path in cache:
    return false

  sami.fullpath         = path
  info["ARTIFACT_PATH"] = pack(path)
  cache[path]           = info
  sami.exclude          = @[]

  sami.flags.incl(SkipWrite)

  dirWalk(true, sami.exclude.add(item))
  # Create a liar SAMI point.
  # Should probably have a bit in the sami.flags field to control.
  sami.primary = SamiPoint(startOffset: 0, present: true)
  return true


method handleWrite*(self:    CodecGitRepo,
                    ctx:     Stream,
                    pre:     string,
                    encoded: Option[string],
                    post:    string) =
  publish("ghost-insert", encoded.get())

method getArtifactInfo*(self: CodecGitRepo, sami: SamiObj): KeyInfo =
  result     = newTable[string, Box]()
  let items  = cache[sami.fullpath]

  if "COMMIT_ID" in items:
    result["HASH"] = items["COMMIT_ID"]
  else:
    result["HASH"] = pack("error reading commit hash")

  result["HASH_FILES"]    = pack(sami.exclude)
  result["ARTIFACT_PATH"] = items["ARTIFACT_PATH"]

registerPlugin("gitrepo", CodecGitRepo())
