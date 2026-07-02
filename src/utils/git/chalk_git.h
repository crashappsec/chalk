#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    char    *commit_id;
    char    *author;
    char    *committer;
    char    *commit_message;
    char    *branch;
    char    *origin_uri;
    char    *vcs_dir;
    char    *date_authored;         /* ISO 8601 with ms + offset */
    char    *date_committed;
    int64_t  timestamp_authored;    /* Unix ms */
    int64_t  timestamp_committed;
    bool     commit_signed;
    char    *tag;
    char    *tagger;
    char    *tag_message;
    char    *date_tagged;
    int64_t  timestamp_tagged;
    bool     tag_signed;
    /* NULL-terminated string arrays; NULL when not requested or empty */
    char   **vcs_missing_files;
    char   **vcs_modified_files;
    char   **vcs_untracked_files;
    /* zero when not requested */
    int64_t  diff_stat_files;
    int64_t  diff_stat_insertions;
    int64_t  diff_stat_deletions;
    /* NULL when not requested */
    char    *diff_patch;
    /* Non-NULL when a libgit2 call in the named phase failed. */
    char    *error_commit;   /* repo open / head resolution / commit peel */
    char    *error_tag;      /* local tag enumeration */
    char    *error_refetch;  /* SSL cert setup / remote tag refetch (best-effort; not fatal) */
    char    *error_status;   /* worktree status (vcs_*_files) */
    char    *error_diff;     /* diff stat / patch */
} chalk_git_result_t;

/* Walk up from path to find the enclosing git repository and return its
 * worktree root as a malloc'd string, or NULL if not inside a repo.
 * Free with free(). */
char *chalk_git_discover_worktree(char *path);

/*
 * Collect git metadata for the repository whose worktree root is repo_root.
 *
 * worktree_status      - populate vcs_{missing,deleted,modified,untracked}_files
 * diff_stat            - populate diff_stat_{files,insertions,deletions}
 * diff_patch           - populate diff_patch (implies diff_stat)
 * collect_tags         - select the latest tag on HEAD and populate its metadata
 * refetch_tags         - fetch lightweight tags from remote before selecting latest
 * connect_timeout_ms   - remote connect timeout for tag refetch (ms; 0 = libgit2 default)
 * transfer_timeout_ms  - remote transfer timeout for tag refetch (ms; 0 = libgit2 default)
 * chalk_cert_path      - chalk's bundled Mozilla CA store path (may be NULL)
 *
 * Returns a heap-allocated struct on success (even if the path is not a repo;
 * fields will simply be NULL/zero).  Returns NULL only on allocation failure.
 * Free with chalk_git_result_free().
 */
chalk_git_result_t *chalk_git_collect(
    char *repo_root,
    bool  worktree_status,
    bool  diff_stat,
    bool  diff_patch,
    bool  collect_tags,
    bool  refetch_tags,
    int   connect_timeout_ms,
    int   transfer_timeout_ms,
    char *chalk_cert_path
);

void chalk_git_result_free(chalk_git_result_t *r);
