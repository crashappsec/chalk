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
  run_management,
  types,
]
import "."/[
  chalkdict,
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
  error_status:         cstring
  error_diff:           cstring

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc chalk_git_discover_worktree(
  path: cstring,
): cstring {.importc: "chalk_git_discover_worktree", cdecl.}

proc chalk_git_collect(
  repoRoot:       cstring,
  worktreeStatus: bool,
  diffStat:       bool,
  diffPatch:      bool,
  refetchTags:    bool,
  chalkCertPath:  cstring,
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
    repoRoot:       string,
    worktreeStatus: bool = false,
    diffStat:       bool = false,
    diffPatch:      bool = false,
    refetchTags:    bool = false,
): ChalkDict =
  result = ChalkDict()
  let r = chalk_git_collect(
    repoRoot       = repoRoot.cstring,
    worktreeStatus = worktreeStatus,
    diffStat       = diffStat or diffPatch,
    diffPatch      = diffPatch,
    refetchTags    = refetchTags,
    chalkCertPath  = getGitCertPath().cstring,
  )
  if r == nil:
    return
  defer: chalk_git_result_free(r)

  if r.error_commit != nil:
    let msg = $r.error_commit
    error("git: commit collection failed for " & repoRoot & ": " & msg)
    addFailedKey(
      "_COMMIT_ID",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect commit metadata for " & repoRoot,
    )

  if r.error_tag != nil:
    let msg = $r.error_tag
    error("git: tag collection failed for " & repoRoot & ": " & msg)
    addFailedKey(
      "_TAG",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect tag metadata for " & repoRoot,
    )

  if r.error_status != nil:
    let msg = $r.error_status
    error("git: worktree status failed for " & repoRoot & ": " & msg)
    for key in ["_VCS_MISSING_FILES", "_VCS_DELETED_FILES",
                "_VCS_MODIFIED_FILES", "_VCS_UNTRACKED_FILES"]:
      addFailedKey(
        key,
        code        = "GIT_COLLECTION_FAILED",
        error       = msg,
        description = "libgit2 failed to collect worktree status for " & repoRoot,
      )

  if r.error_diff != nil:
    let msg = $r.error_diff
    error("git: diff collection failed for " & repoRoot & ": " & msg)
    addFailedKey(
      "_VCS_DIFF_STAT",
      code        = "GIT_COLLECTION_FAILED",
      error       = msg,
      description = "libgit2 failed to collect diff stats for " & repoRoot,
    )
    if diffPatch:
      addFailedKey(
        "_VCS_DIFF_PATCH",
        code        = "GIT_COLLECTION_FAILED",
        error       = msg,
        description = "libgit2 failed to collect diff patch for " & repoRoot,
      )

  if r.commit_id           != nil: result["COMMIT_ID"]            = pack($r.commit_id)
  if r.author              != nil: result["AUTHOR"]               = pack($r.author)
  if r.committer           != nil: result["COMMITTER"]            = pack($r.committer)
  if r.commit_message      != nil: result["COMMIT_MESSAGE"]       = pack($r.commit_message)
  if r.branch              != nil: result["BRANCH"]               = pack($r.branch)
  if r.origin_uri          != nil: result["ORIGIN_URI"]           = pack($r.origin_uri)
  if r.vcs_dir             != nil: result["VCS_DIR_WHEN_CHALKED"] = pack($r.vcs_dir)
  if r.date_authored       != nil: result["DATE_AUTHORED"]        = pack($r.date_authored)
  if r.date_committed      != nil: result["DATE_COMMITTED"]       = pack($r.date_committed)
  if r.timestamp_authored  != 0:   result["TIMESTAMP_AUTHORED"]   = pack(r.timestamp_authored)
  if r.timestamp_committed != 0:   result["TIMESTAMP_COMMITTED"]  = pack(r.timestamp_committed)
  if r.commit_id           != nil: result["COMMIT_SIGNED"]        = pack(r.commit_signed)
  if r.tag                 != nil: result["TAG"]                  = pack($r.tag)
  if r.tagger              != nil: result["TAGGER"]               = pack($r.tagger)
  if r.tag_message         != nil: result["TAG_MESSAGE"]          = pack($r.tag_message)
  if r.date_tagged         != nil: result["DATE_TAGGED"]          = pack($r.date_tagged)
  if r.timestamp_tagged    != 0:   result["TIMESTAMP_TAGGED"]     = pack(r.timestamp_tagged)
  if r.tag                 != nil: result["TAG_SIGNED"]           = pack(r.tag_signed)

  let
    missingFiles   = cstringArrayToSeq(r.vcs_missing_files)
    deletedFiles   = cstringArrayToSeq(r.vcs_deleted_files)
    modifiedFiles  = cstringArrayToSeq(r.vcs_modified_files)
    untrackedFiles = cstringArrayToSeq(r.vcs_untracked_files)

  if missingFiles.len   > 0: result["VCS_MISSING_FILES"]   = pack(missingFiles)
  if deletedFiles.len   > 0: result["VCS_DELETED_FILES"]   = pack(deletedFiles)
  if modifiedFiles.len  > 0: result["VCS_MODIFIED_FILES"]  = pack(modifiedFiles)
  if untrackedFiles.len > 0: result["VCS_UNTRACKED_FILES"] = pack(untrackedFiles)

  if r.commit_id != nil and (diffStat or diffPatch):
    let statDict = ChalkDict()
    statDict["files"]      = pack(r.diff_stat_files)
    statDict["insertions"] = pack(r.diff_stat_insertions)
    statDict["deletions"]  = pack(r.diff_stat_deletions)
    result["VCS_DIFF_STAT"] = pack(statDict)

  if r.diff_patch != nil:
    result["VCS_DIFF_PATCH"] = pack($r.diff_patch)
