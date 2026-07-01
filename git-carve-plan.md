# Plan: Carving n00b's Git Logic into Chalk (main branch)

## Status: COMPLETE

All 15 git functional tests pass. The branch is `libn00b`.

---

## Context

The goal is to do what the macho integration does: carve out only the git C
source from n00b and compile it directly into chalk, linking only `libgit2`.
We are working from main, so there is no n00b runtime, no `src/n00b/` folder,
and no libn00b linkage to deal with.

---

## Key design decisions

- **No shims.** The C function returns a plain `chalk_git_result_t *` struct
  using only standard C types (`char *`, `char **`, `int64_t`, `bool`).
  libgit2 calls happen inside the C file; the Nim side only sees the struct.
- **No dict layer.** The original n00b implementation built an
  `n00b_dict_t` and then converted it. We skip that entirely - the C
  function populates the struct directly.
- **Delete old parser.** The existing Nim git object parser in `vctlGit.nim`
  (~650 lines) is removed in full.
- **Diff patch in scope.** `VCS_DIFF_PATCH` and the worktree status keys
  (`VCS_MODIFIED_FILES`, `VCS_DELETED_FILES`, etc.) are included.

---

## SSH transport design

libgit2 is compiled with `USE_SSH=exec` (no libssh2 dependency). The exec
transport spawns the real `ssh` binary via `/bin/sh -c`, exactly like `git`
does.

### Environment variable mapping

| Variable          | `git` | libgit2 exec transport |
| ----------------- | ----- | ---------------------- |
| `GIT_SSH_COMMAND` | yes   | no                     |
| `GIT_SSH`         | yes   | yes                    |
| `SSH_AUTH_SOCK`   | yes   | yes (inherited by ssh) |
| `core.sshCommand` | yes   | yes                    |

`GIT_SSH_COMMAND` is the variable CI systems and users typically set (it
supports shell quoting and flags, e.g.
`GIT_SSH_COMMAND="ssh -i ~/.ssh/deploy_key -o StrictHostKeyChecking=no"`).
The exec transport reads `GIT_SSH` instead.

### Bridge: `write_ssh_command_wrapper`

When `GIT_SSH_COMMAND` is set and `GIT_SSH` is not, `chalk_git.c` writes a
small temp executable script to `$TMPDIR/chalk_ssh_XXXXXX`:

```sh
#!/bin/sh
exec sh -c "$GIT_SSH_COMMAND" -- "$@"
```

`$GIT_SSH` is pointed at this wrapper for the duration of the fetch, then
unlinked and unset. If `$GIT_SSH` is already set the caller controls the SSH
binary and the wrapper is skipped entirely.

If neither variable is set, exec transport falls back to system `ssh` and
inherits `$SSH_AUTH_SOCK`, so agent forwarding works with no extra setup.

### User-facing documentation

The `git` singleton in `chalk.c42spec` documents:

- `GIT_SSH_COMMAND` as the primary way to customise the SSH binary.
- SSH agent forwarding via `SSH_AUTH_SOCK`.
- The requirement that one of the above must be configured for SSH remotes
  to authenticate during `refetch_lightweight_tags`.

---

## Phase 1 - Write the C implementation (`src/utils/git/`)

Create a small self-contained C module. No n00b types anywhere.

**`src/utils/git/chalk_git.h`** - public header declaring:

- `chalk_git_result_t` struct (all fields `char *`, `char **`, `int64_t`, `bool`)
- `char *chalk_git_discover_worktree(char *path)` - walks up from `path` to find
  the enclosing git worktree root; caller frees with `free()`
- `chalk_git_result_t *chalk_git_collect(char *repo_root, bool worktree_status,
bool diff_stat, bool diff_patch, bool refetch_tags)`
- `void chalk_git_result_free(chalk_git_result_t *r)`

**`src/utils/git/chalk_git.c`** - implementation compiled with `-std=c11`.

Logic ported from n00b's `src/util/git.nc` into plain C, replacing all n00b
type usage with struct fields and standard C. Key functions:

| n00b function                   | plain C equivalent                              |
| ------------------------------- | ----------------------------------------------- |
| `select_latest_tag`             | static helper, populates `best_tag_t`           |
| `maybe_refetch_lightweight_tag` | gated by `refetch_tags` bool (no env var)       |
| `signature_person`              | `snprintf` into `malloc`'d buffer               |
| `format_iso8601`                | `strftime` + manual offset formatting           |
| `set_missing_files`             | populates `char **` arrays via `realloc`        |
| `set_diff_stat`                 | populates `diff_stat_*` fields and `diff_patch` |
| `resolve_origin`                | populates `origin_uri` field                    |
| `sanitize_origin`               | strips credentials from http(s) URLs            |
| `n00b_git_collect`              | `chalk_git_collect`, writes struct directly     |
| (new) discover worktree         | `chalk_git_discover_worktree` via libgit2       |

Refetch behaviour: `maybe_refetch_lightweight_tag` only fires when the selected
tag is lightweight (`!best->annotated`) and the caller passes `refetch_tags =
true`. No env vars used - the bool fully controls the behaviour.

All string outputs are `strdup`'d so `chalk_git_result_free` can `free` them
uniformly. `char **` list fields are `NULL`-terminated and each element is
`strdup`'d.

---

## Phase 2 - libgit2 build integration

Add libgit2 to `../nimutils/bin/buildlibs.sh` following the existing pattern.
Add `git2` to the `staticLinkLibraries` call in `config.nims`.

libgit2 is built with:

```
-DUSE_SSH=exec       # exec transport; no libssh2 dependency
-DUSE_HTTPS=OpenSSL  # HTTPS via our statically linked OpenSSL
-DUSE_NTLMCLIENT=OFF
-DREGEX_BACKEND=builtin
```

libgit2 headers come from the system build - no `include/` subdir needed under
`src/utils/git/`.

---

## Phase 3 - Nim wrapper (merged into `src/utils/git.nim`)

The FFI wrappers live in `src/utils/git.nim` alongside the existing
subprocess-based helpers (`setGitExeLocation`, `getGitExeLocation`). No
separate `gitCollect.nim` file.

Exported procs:

```nim
proc gitDiscoverWorkTree*(path: string): string
  ## Returns the worktree root for the repo containing path, or "".

proc gitCollect*(
    repoRoot:       string,
    worktreeStatus: bool = false,
    diffStat:       bool = false,
    diffPatch:      bool = false,
    refetchTags:    bool = false,
): ChalkDict
```

`gitCollect` maps every non-nil / non-zero struct field to a chalk key.
`cstringArrayToSeq` from Nim stdlib converts the `char **` arrays.

Error fields from the struct (`error_commit`, `error_tag`, `error_refetch`,
`error_status`, `error_diff`) are logged at `error:` level except
`error_refetch` which is `warn:` (network failures during refetch are
best-effort) and also recorded in `_OP_FAILED_KEYS` with code
`GIT_REFETCH_FAILED`.

---

## Phase 4 - Refactor `vctlGit.nim`

**Deleted** all old Nim git parsing (pack file reader, object parser, git
config parser, `RepoInfo`, `GitTag`, `findGitDir`, etc.).

**`GitInfo`** cache object:

```nim
type GitInfo = ref object of RootRef
  repos:     OrderedTable[string, string]  # artifact path -> worktree root
  worktrees: OrderedTable[string, bool]    # worktree root -> discovered
```

**Discovery** uses `gitDiscoverWorkTree(path)` (libgit2 walk) instead of the
old manual `.git` directory search.

**`setVcsKeys`** calls `gitCollect` with flags derived from `isSubscribedKey`,
then filters each returned key through `isSubscribedKey` before storing.

**`refetchTags`** reads `attrGet[bool]("git.refetch_lightweight_tags")` directly
(no try/except wrapper).

---

## Phase 5 - `boxToJson` Unicode fix (nimutils)

`nimutils/nimutils/box.nim` `boxToJson` MkStr branch replaced `escapeJson` with
a `runes()`-based encoder that emits `\uXXXX` (and surrogate pairs for
codepoints >= U+10000) for all non-ASCII bytes. This keeps the chalk mark
7-bit ASCII-clean so `strings chalk | grep MAGIC | jq` works without the mark
being split across lines by multi-byte UTF-8 sequences.

`chalkjson.nim` was reverted to call `boxToJson` directly (the temporary
`chalkBoxToJson` wrapper removed).

---

## New files

```
src/utils/git/
  chalk_git.h    # public struct + function declarations
  chalk_git.c    # libgit2-based implementation
```

`src/utils/git.nim` extended with the FFI wrappers (previously a separate
`gitCollect.nim`, now merged).

`../nimutils/bin/buildlibs.sh` gains the `ensure_libgit2` function.
