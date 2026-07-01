##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The plugin responsible for pulling metadata from the git repository
## via libgit2 (compiled in via src/utils/git/chalk_git.c).

import std/[
  sets,
]
import ".."/[
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/git,
]

type GitInfo = ref object of RootRef
  repos:     OrderedTable[string, string]      # artifact path -> repo worktree root
  worktrees: OrderedSet[string]                # discovered worktree roots
  collected: OrderedTable[string, GitRepoInfo] # worktree -> cached result

proc clearCallback(self: Plugin) {.cdecl.} =
  self.internalState = RootRef(GitInfo())

proc isInRepo(obj: ChalkObj, repo: string): bool =
  if obj.fsRef == "":
    return false
  return obj.fsRef.resolvePath().startsWith(repo)

proc findAndLoad(plugin: GitInfo, path: string) =
  trace("Looking for git worktree, from: " & path)
  let worktree = gitDiscoverWorkTree(path)
  if worktree == "" or worktree in plugin.worktrees:
    return
  trace("Found git worktree: " & worktree)
  plugin.worktrees.incl(worktree)
  plugin.repos[path]         = worktree

proc gitInit(self: Plugin) =
  let cache = GitInfo(self.internalState)
  if len(cache.worktrees) == 0:
    for path in getContextDirectories():
      cache.findAndLoad(path.resolvePath())

proc getRepoFor*(self: Plugin, path: string): string =
  self.gitInit()
  let
    cache    = GitInfo(self.internalState)
    resolved = path.resolvePath()
  if resolved in cache.repos:
    return cache.repos[resolved]
  else:
    trace("git: " & path & " is not inside git repo")
    raise newException(KeyError, "not in git repo")

proc gitFirstDir*(self: Plugin): Option[string] =
  self.gitInit()
  let cache = GitInfo(self.internalState)
  for worktree in cache.worktrees:
    return some(worktree)
  return none(string)

proc collectVcsData(cache: GitInfo, worktree: string): GitRepoInfo =
  if worktree in cache.collected:
    return cache.collected[worktree]
  let
    # Check both chalk-time and runtime prefixes so collection is not
    # order-dependent (whichever callback fires first gets the full data).
    needWorktree  = (isSubscribedKey("VCS_MISSING_FILES")   or isSubscribedKey("_VCS_MISSING_FILES")   or
                     isSubscribedKey("VCS_DELETED_FILES")   or isSubscribedKey("_VCS_DELETED_FILES")   or
                     isSubscribedKey("VCS_MODIFIED_FILES")  or isSubscribedKey("_VCS_MODIFIED_FILES")  or
                     isSubscribedKey("VCS_UNTRACKED_FILES") or isSubscribedKey("_VCS_UNTRACKED_FILES"))
    needDiffStat  = (isSubscribedKey("VCS_DIFF_STAT")       or isSubscribedKey("_VCS_DIFF_STAT"))
    needDiffPatch = (isSubscribedKey("VCS_DIFF_PATCH")      or isSubscribedKey("_VCS_DIFF_PATCH"))
    needTags      = (isSubscribedKey("TAG")                 or isSubscribedKey("_TAG")              or
                     isSubscribedKey("TAGGER")              or isSubscribedKey("_TAGGER")           or
                     isSubscribedKey("TAG_MESSAGE")         or isSubscribedKey("_TAG_MESSAGE")      or
                     isSubscribedKey("DATE_TAGGED")         or isSubscribedKey("_DATE_TAGGED")      or
                     isSubscribedKey("TIMESTAMP_TAGGED")    or isSubscribedKey("_TIMESTAMP_TAGGED") or
                     isSubscribedKey("TAG_SIGNED")          or isSubscribedKey("_TAG_SIGNED"))
    refetch           = needTags and attrGet[bool]("git.refetch_lightweight_tags")
    connectTimeoutMs  = int(attrGet[Con4mDuration]("git.fetch_connect_timeout"))  div 1000
    transferTimeoutMs = int(attrGet[Con4mDuration]("git.fetch_transfer_timeout")) div 1000
  result = gitCollect(
    repoRoot          = worktree,
    worktreeStatus    = needWorktree,
    diffStat          = needDiffStat,
    diffPatch         = needDiffPatch,
    collectTags       = needTags,
    refetchTags       = refetch,
    connectTimeoutMs  = connectTimeoutMs,
    transferTimeoutMs = transferTimeoutMs,
  )

  if result.errorCommit != "":
    let msg = result.errorCommit
    error("git: commit collection failed for " & worktree & ": " & msg)
    addFailedKey(
      "_COMMIT_ID",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect commit metadata for " & worktree,
    )
  if result.errorTag != "":
    let msg = result.errorTag
    error("git: tag collection failed for " & worktree & ": " & msg)
    addFailedKey(
      "_TAG",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect tag metadata for " & worktree,
    )
  if result.errorRefetch != "":
    let msg = result.errorRefetch
    warn("git: tag refetch failed for " & worktree & ": " & msg)
    addFailedKey(
      "_TAG",
      code        = "GIT_REFETCH_FAILED",
      error       = msg,
      description = "libgit2 failed to refetch lightweight tags from remote for " & worktree,
    )
  if result.errorStatus != "":
    let msg = result.errorStatus
    error("git: worktree status failed for " & worktree & ": " & msg)
    for key in [
      "_VCS_MISSING_FILES",
      "_VCS_DELETED_FILES",
      "_VCS_MODIFIED_FILES",
      "_VCS_UNTRACKED_FILES",
    ]:
      addFailedKey(
        key,
        code        = "GIT_COLLECTION_FAILED",
        error       = msg,
        description = "libgit2 failed to collect worktree status for " & worktree,
      )
  if result.errorDiff != "":
    let msg = result.errorDiff
    error("git: diff collection failed for " & worktree & ": " & msg)
    addFailedKey(
      "_VCS_DIFF_STAT",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect diff stats for " & worktree,
    )
    if needDiffPatch:
      addFailedKey(
        "_VCS_DIFF_PATCH",
        code        = "GIT_COLLECTION_FAILED",
        error       = msg,
        description = "libgit2 failed to collect diff patch for " & worktree,
      )

  cache.collected[worktree] = result

proc packGitInfo(info: GitRepoInfo, prefix: string): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded(prefix & "COMMIT_ID",            info.commitId)
  result.setIfNeeded(prefix & "AUTHOR",               info.author)
  result.setIfNeeded(prefix & "COMMITTER",            info.committer)
  result.setIfNeeded(prefix & "COMMIT_MESSAGE",       info.commitMessage)
  result.setIfNeeded(prefix & "BRANCH",               info.branch)
  result.setIfNeeded(prefix & "ORIGIN_URI",           info.originUri)
  result.setIfNeeded(prefix & "VCS_DIR_WHEN_CHALKED", info.vcsDir)
  if info.dateAuthored != "":
    result.setIfNeeded(prefix & "DATE_AUTHORED",       info.dateAuthored)
    result.setIfNeeded(prefix & "TIMESTAMP_AUTHORED",  info.timestampAuthored)
  if info.dateCommitted != "":
    result.setIfNeeded(prefix & "DATE_COMMITTED",      info.dateCommitted)
    result.setIfNeeded(prefix & "TIMESTAMP_COMMITTED", info.timestampCommitted)
  if info.commitId != "":
    result.setIfNeeded(prefix & "COMMIT_SIGNED",       info.commitSigned)
  result.setIfNeeded(prefix & "TAG",         info.tag)
  result.setIfNeeded(prefix & "TAGGER",      info.tagger)
  result.setIfNeeded(prefix & "TAG_MESSAGE", info.tagMessage)
  if info.dateTagged != "":
    result.setIfNeeded(prefix & "DATE_TAGGED",         info.dateTagged)
    result.setIfNeeded(prefix & "TIMESTAMP_TAGGED",    info.timestampTagged)
  if info.tag != "":
    result.setIfNeeded(prefix & "TAG_SIGNED",          info.tagSigned)
  result.setIfNeeded(prefix & "VCS_MISSING_FILES",   info.missingFiles)
  result.setIfNeeded(prefix & "VCS_DELETED_FILES",   info.deletedFiles)
  result.setIfNeeded(prefix & "VCS_MODIFIED_FILES",  info.modifiedFiles)
  result.setIfNeeded(prefix & "VCS_UNTRACKED_FILES", info.untrackedFiles)
  if info.hasDiffStat:
    let statDict = ChalkDict()
    statDict["files"]      = pack(info.diffStatFiles)
    statDict["insertions"] = pack(info.diffStatInsertions)
    statDict["deletions"]  = pack(info.diffStatDeletions)
    result.setIfNeeded(prefix & "VCS_DIFF_STAT", statDict)
  result.setIfNeeded(prefix & "VCS_DIFF_PATCH", info.diffPatch)

proc setVcsKeys(cache: GitInfo, result: ChalkDict, worktree: string, prefix = "") =
  let info =
    try:
      cache.collectVcsData(worktree)
    except:
      dumpExOnDebug()
      error("git: failed to collect info for " & worktree & ": " & getCurrentExceptionMsg())
      return
  for k, v in packGitInfo(info, prefix):
    result[k] = v

proc gitGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                 ChalkDict {.cdecl.} =
  self.gitInit()
  result    = ChalkDict()
  let cache = GitInfo(self.internalState)

  if len(cache.worktrees) == 0:
    return

  if obj.fsRef == "":
    let first = self.gitFirstDir()
    if first.isSome():
      cache.setVcsKeys(result, first.get())
    return

  for worktree in cache.worktrees:
    if obj.isInRepo(worktree):
      cache.setVcsKeys(result, worktree)
      break

proc gitGetRunTimeArtifactInfo*(self:  Plugin,
                                chalk: ChalkObj,
                                ins:   bool,
                               ): ChalkDict {.cdecl.} =
  self.gitInit()
  result = ChalkDict()
  if chalk.fsRef == "":
    return
  let cache = GitInfo(self.internalState)
  for worktree in cache.worktrees:
    result.setIfNeeded(
      "_OP_ARTIFACT_PATH_WITHIN_VCTL",
      getRelativePathBetween(worktree, chalk.fsRef),
    )

proc gitGetRunTimeHostInfo(self: Plugin, chalks: seq[ChalkObj]):
                           ChalkDict {.cdecl.} =
  self.gitInit()
  result    = ChalkDict()
  let cache = GitInfo(self.internalState)
  let first = self.gitFirstDir()
  if first.isSome():
    cache.setVcsKeys(result, first.get(), prefix = "_")

proc loadVctlGit*() =
  newPlugin(
    "vctl_git",
    clearCallback  = PluginClearCb(clearCallback),
    ctArtCallback  = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
    rtArtCallback  = RunTimeArtifactCb(gitGetRunTimeArtifactInfo),
    rtHostCallback = RunTimeHostCb(gitGetRunTimeHostInfo),
    cache          = RootRef(GitInfo()),
  )
