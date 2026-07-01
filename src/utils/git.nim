##
## Copyright (c) 2024-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
]
import ".."/[
  types,
]
import "."/[
  exe,
]
import pkg/[
  nimutils,
]

var gitExeLocation = ""

proc setGitExeLocation*() =
  once:
    gitExeLocation = exe.findExePath("git").get("")
    if gitExeLocation == "":
      error("No git command found in PATH")
      raise newException(ValueError, "No git")

proc getGitExeLocation*(): string =
  once:
    try:
      setGitExeLocation()
    except:
      discard
  return gitExeLocation

const
  gitSrcDir = currentSourcePath.parentDir / "git"
  gitCFlags = "-std=c11"

{.compile(gitSrcDir / "chalk_git.c", gitCFlags).}

type ChalkGitResult {.importc: "chalk_git_result_t",
                      header: gitSrcDir / "chalk_git.h", pure.} = object
  commit_id:            cstring
  author:               cstring
  committer:            cstring
  commit_message:       cstring
  branch:               cstring
  origin_uri:           cstring
  vcs_dir:              cstring
  date_authored:        cstring
  date_committed:       cstring
  timestamp_authored:   int64
  timestamp_committed:  int64
  commit_signed:        bool
  tag:                  cstring
  tagger:               cstring
  tag_message:          cstring
  date_tagged:          cstring
  timestamp_tagged:     int64
  tag_signed:           bool
  vcs_missing_files:    cstringArray
  vcs_deleted_files:    cstringArray
  vcs_modified_files:   cstringArray
  vcs_untracked_files:  cstringArray
  diff_stat_files:      int64
  diff_stat_insertions: int64
  diff_stat_deletions:  int64
  diff_patch:           cstring
  error_commit:         cstring
  error_tag:            cstring
  error_refetch:        cstring
  error_status:         cstring
  error_diff:           cstring

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc chalk_git_discover_worktree(
  path: cstring,
): cstring {.importc: "chalk_git_discover_worktree", cdecl.}

proc chalk_git_collect(
  repoRoot:          cstring,
  worktreeStatus:    bool,
  diffStat:          bool,
  diffPatch:         bool,
  collectTags:       bool,
  refetchTags:       bool,
  connectTimeoutMs:  cint,
  transferTimeoutMs: cint,
  chalkCertPath:     cstring,
): ptr ChalkGitResult {.importc: "chalk_git_collect", cdecl.}

proc chalk_git_result_free(
  r: ptr ChalkGitResult,
) {.importc: "chalk_git_result_free", cdecl.}

proc getGitCertPath(): string =
  try:
    return getCAStorePath()
  except:
    dumpExOnDebug()
  return ""

proc gitDiscoverWorkTree*(path: string): string =
  let r = chalk_git_discover_worktree(path.cstring)
  if r == nil:
    return ""
  result = $r
  c_free(r)

proc gitCollect*(
    repoRoot:          string,
    worktreeStatus:    bool = false,
    diffStat:          bool = false,
    diffPatch:         bool = false,
    collectTags:       bool = true,
    refetchTags:       bool = false,
    connectTimeoutMs:  int  = 0,
    transferTimeoutMs: int  = 0,
): GitRepoInfo =
  result = GitRepoInfo()
  let r = chalk_git_collect(
    repoRoot          = repoRoot.cstring,
    worktreeStatus    = worktreeStatus,
    diffStat          = diffStat or diffPatch,
    diffPatch         = diffPatch,
    collectTags       = collectTags,
    refetchTags       = refetchTags,
    connectTimeoutMs  = connectTimeoutMs.cint,
    transferTimeoutMs = transferTimeoutMs.cint,
    chalkCertPath     = getGitCertPath().cstring,
  )
  if r == nil:
    raise newException(ValueError, "libgit2 failed to collect git info for " & repoRoot)
  defer: chalk_git_result_free(r)

  if r.error_commit  != nil: result.errorCommit  = $r.error_commit
  if r.error_tag     != nil: result.errorTag     = $r.error_tag
  if r.error_refetch != nil: result.errorRefetch = $r.error_refetch
  if r.error_status  != nil: result.errorStatus  = $r.error_status
  if r.error_diff    != nil: result.errorDiff    = $r.error_diff

  if r.commit_id      != nil: result.commitId      = $r.commit_id
  if r.author         != nil: result.author        = $r.author
  if r.committer      != nil: result.committer     = $r.committer
  if r.commit_message != nil: result.commitMessage = $r.commit_message
  if r.branch         != nil: result.branch        = $r.branch
  if r.origin_uri     != nil: result.originUri     = $r.origin_uri
  if r.vcs_dir        != nil: result.vcsDir        = $r.vcs_dir
  if r.date_authored  != nil:
    result.dateAuthored       = $r.date_authored
    result.timestampAuthored  = r.timestamp_authored
  if r.date_committed != nil:
    result.dateCommitted      = $r.date_committed
    result.timestampCommitted = r.timestamp_committed
  if r.commit_id != nil:
    result.commitSigned = r.commit_signed
  if r.tag         != nil: result.tag        = $r.tag
  if r.tagger      != nil: result.tagger     = $r.tagger
  if r.tag_message != nil: result.tagMessage = $r.tag_message
  if r.date_tagged != nil:
    result.dateTagged      = $r.date_tagged
    result.timestampTagged = r.timestamp_tagged
  if r.tag != nil:
    result.tagSigned = r.tag_signed

  result.missingFiles   = cstringArrayToSeq(r.vcs_missing_files)
  result.deletedFiles   = cstringArrayToSeq(r.vcs_deleted_files)
  result.modifiedFiles  = cstringArrayToSeq(r.vcs_modified_files)
  result.untrackedFiles = cstringArrayToSeq(r.vcs_untracked_files)

  if r.commit_id != nil and (diffStat or diffPatch):
    result.hasDiffStat        = true
    result.diffStatFiles      = r.diff_stat_files
    result.diffStatInsertions = r.diff_stat_insertions
    result.diffStatDeletions  = r.diff_stat_deletions

  if r.diff_patch != nil:
    result.diffPatch = $r.diff_patch
