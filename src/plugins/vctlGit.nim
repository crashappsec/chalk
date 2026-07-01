##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The plugin responsible for pulling metadata from the git repository
## via libgit2 (compiled in via src/utils/git/chalk_git.c).

import ".."/[
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/git,
]

type GitInfo = ref object of RootRef
  repos:     OrderedTable[string, string]     # artifact path -> repo worktree root
  worktrees: OrderedTable[string, bool]       # worktree root -> discovered
  collected: OrderedTable[string, ChalkDict]  # "worktree|prefix" -> cached result

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
  plugin.worktrees[worktree] = true
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
  for worktree, _ in cache.worktrees:
    return some(worktree)
  return none(string)

proc collectVcsData(cache: GitInfo, worktree: string, prefix = ""): ChalkDict =
  if worktree in cache.collected:
    return cache.collected[worktree]
  let
    needWorktree  = (isSubscribedKey(prefix & "VCS_MISSING_FILES")   or
                     isSubscribedKey(prefix & "VCS_DELETED_FILES")    or
                     isSubscribedKey(prefix & "VCS_MODIFIED_FILES")   or
                     isSubscribedKey(prefix & "VCS_UNTRACKED_FILES"))
    needDiffStat  = isSubscribedKey(prefix & "VCS_DIFF_STAT")
    needDiffPatch = isSubscribedKey(prefix & "VCS_DIFF_PATCH")
    needTags      = (isSubscribedKey(prefix & "TAG")             or
                     isSubscribedKey(prefix & "TAGGER")          or
                     isSubscribedKey(prefix & "TAG_MESSAGE")      or
                     isSubscribedKey(prefix & "DATE_TAGGED")      or
                     isSubscribedKey(prefix & "TIMESTAMP_TAGGED") or
                     isSubscribedKey(prefix & "TAG_SIGNED"))
    refetch       = needTags and attrGet[bool]("git.refetch_lightweight_tags")
  result = gitCollect(
    repoRoot       = worktree,
    worktreeStatus = needWorktree,
    diffStat       = needDiffStat,
    diffPatch      = needDiffPatch,
    collectTags    = needTags,
    refetchTags    = refetch,
  )
  cache.collected[worktree] = result

proc setVcsKeys(cache: GitInfo, result: ChalkDict, worktree: string, prefix = "") =
  for k, v in cache.collectVcsData(worktree, prefix):
    result.setIfNeeded(prefix & k, v)

proc gitGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                 ChalkDict {.cdecl.} =
  self.gitInit()
  result    = ChalkDict()
  let cache = GitInfo(self.internalState)

  if len(cache.worktrees) == 0:
    return

  if obj.fsRef == "":
    for worktree, _ in cache.worktrees:
      cache.setVcsKeys(result, worktree)
      break
    return

  for worktree, _ in cache.worktrees:
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
  for worktree, _ in cache.worktrees:
    result.setIfNeeded(
      "_OP_ARTIFACT_PATH_WITHIN_VCTL",
      getRelativePathBetween(worktree, chalk.fsRef),
    )

proc gitGetRunTimeHostInfo(self: Plugin, chalks: seq[ChalkObj]):
                           ChalkDict {.cdecl.} =
  self.gitInit()
  result    = ChalkDict()
  let cache = GitInfo(self.internalState)
  for worktree, _ in cache.worktrees:
    cache.setVcsKeys(result, worktree, prefix = "_")
    break

proc loadVctlGit*() =
  newPlugin(
    "vctl_git",
    clearCallback  = PluginClearCb(clearCallback),
    ctArtCallback  = ChalkTimeArtifactCb(gitGetChalkTimeArtifactInfo),
    rtArtCallback  = RunTimeArtifactCb(gitGetRunTimeArtifactInfo),
    rtHostCallback = RunTimeHostCb(gitGetRunTimeHostInfo),
    cache          = RootRef(GitInfo()),
  )
