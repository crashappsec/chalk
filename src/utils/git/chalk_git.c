/*
 * Copyright (c) 2025-2026, Crash Override, Inc.
 *
 * This file is part of Chalk (see https://crashoverride.com/docs/chalk).
 *
 * Git metadata collection via libgit2.  Plain C23, no n00b runtime.
 * Logic ported from n00b/src/util/git.nc.
 */

/* Expose POSIX.1-2008 extensions (strdup, strndup, etc.) even under -std=c11. */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <git2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "chalk_git.h"

/* Capture the current libgit2 error into out->field (first error wins). */
#define CAPTURE_GIT_ERROR(out, field, fallback)                         \
    do {                                                                \
        if (!(out)->field) {                                            \
            const git_error *_ge = git_error_last();                    \
            (out)->field = strdup((_ge && _ge->message)                 \
                                  ? _ge->message : (fallback));         \
        }                                                               \
    } while (0)

static const char gpg_sig_start[] = "-----BEGIN PGP SIGNATURE-----";
static const char gpg_sig_end[]   = "-----END PGP SIGNATURE-----";

/* =========================================================================
 * SSL certificate setup for libgit2 HTTPS.
 * ========================================================================= */

/* Set up SSL certificate locations for libgit2.
 *
 * GIT_OPT_SET_SSL_CERT_LOCATIONS calls SSL_CTX_load_verify_locations, which
 * is additive: each call accumulates into the same X509_STORE.  We exploit
 * this to load system certs (bundle file + hash-named cert dir) and chalk's
 * bundled Mozilla CA store independently, without concatenating files.
 *
 * CApath directories must contain OpenSSL hash-named files (e.g. abc123.0),
 * as created by c_rehash / update-ca-certificates / update-ca-trust. */
static void
setup_ssl_certs(chalk_git_result_t *out, const char *chalk_cert_path)
{
    /* Resolve system cert file: explicit env var takes priority. */
    const char *system_file = getenv("SSL_CERT_FILE");
    if (!system_file) {
        static const char *bundle_paths[] = {
            "/etc/ssl/certs/ca-certificates.crt",           /* Debian/Ubuntu/Arch/Alpine/Gentoo */
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", /* RHEL/CentOS/Fedora 7+     */
            "/etc/pki/tls/certs/ca-bundle.crt",             /* RHEL/CentOS/Fedora 6              */
            "/etc/ssl/ca-bundle.pem",                       /* OpenSUSE                          */
            "/var/lib/ca-certificates/ca-bundle.pem",       /* OpenSUSE newer                    */
            "/usr/share/ssl/certs/ca-bundle.crt",           /* older distributions               */
            "/etc/ssl/cert.pem",                            /* OpenBSD/some minimal systems      */
            NULL,
        };
        for (int i = 0; bundle_paths[i]; i++) {
            if (access(bundle_paths[i], R_OK) == 0) {
                system_file = bundle_paths[i];
                break;
            }
        }
    }

    /* Resolve system cert dir: explicit env var takes priority.
     * Directories must contain c_rehash-style hash-named files. */
    const char *system_dir = getenv("SSL_CERT_DIR");
    if (!system_dir) {
        static const char *dir_paths[] = {
            "/etc/ssl/certs",                               /* Debian/Ubuntu/Arch/Alpine/Gentoo */
            "/etc/pki/ca-trust/extracted/openssl",          /* RHEL/CentOS/Fedora (openssl fmt) */
            "/etc/pki/tls/certs",                           /* RHEL/CentOS fallback             */
            NULL,
        };
        for (int i = 0; dir_paths[i]; i++) {
            if (access(dir_paths[i], R_OK) == 0) {
                system_dir = dir_paths[i];
                break;
            }
        }
    }

    /* Load system certs (file + dir are both additive, either may be NULL). */
    if (system_file || system_dir) {
        if (git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, system_file, system_dir) < 0) {
            CAPTURE_GIT_ERROR(out, error_tag, "failed to load system SSL certs");
        }
    }

    /* Load chalk's bundled Mozilla CA store on top of system certs.
     * Additive: does not replace what was loaded above. */
    if (chalk_cert_path && *chalk_cert_path && access(chalk_cert_path, R_OK) == 0) {
        if (git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, chalk_cert_path, NULL) < 0) {
            CAPTURE_GIT_ERROR(out, error_tag, "failed to load chalk bundled SSL certs");
        }
    }
}

/* =========================================================================
 * Small dynamic string-list used for worktree status arrays.
 * ========================================================================= */

typedef struct {
    char  **items;
    size_t  count;
    size_t  cap;
} str_list_t;

static void
str_list_append(str_list_t *list, const char *s)
{
    /* keep cap > count so items[count] is always writable for NULL term */
    if (list->count + 1 >= list->cap) {
        size_t  new_cap   = list->cap ? list->cap * 2 : 8;
        char  **new_items = realloc(list->items, new_cap * sizeof(char *));
        if (!new_items) {
            return;
        }
        list->items = new_items;
        list->cap   = new_cap;
    }
    char *copy = strdup(s);
    if (!copy) {
        return;
    }
    list->items[list->count++] = copy;
}

/* Finalise: write NULL terminator and return ownership to caller.
 * Returns NULL if the list is empty (and frees any allocation). */
static char **
str_list_finish(str_list_t *list)
{
    if (!list->count) {
        free(list->items);
        return NULL;
    }
    list->items[list->count] = NULL;
    char **ret  = list->items;
    list->items = NULL;
    return ret;
}

/* =========================================================================
 * String helpers.
 * ========================================================================= */

/* strdup and right-trim trailing slashes. */
static char *
strdup_rtrim_slash(const char *s)
{
    if (!s) {
        return NULL;
    }
    size_t len = strlen(s);
    while (len > 1 && s[len - 1] == '/') {
        len--;
    }
    return strndup(s, len);
}

/* Return the parent directory of path (strdup'd).  "/" returns "/". */
static char *
parent_dir_str(const char *path)
{
    if (!path || !*path) {
        return NULL;
    }
    const char *slash = strrchr(path, '/');
    if (!slash || slash == path) {
        return strdup("/");
    }
    return strndup(path, (size_t)(slash - path));
}

/* Trim leading and trailing whitespace; returns NULL for blank input. */
static char *
trim_cstr(const char *s, size_t len)
{
    if (!s) {
        return NULL;
    }
    const char *end = s + len;
    while (s < end && isspace((unsigned char)*s)) {
        s++;
    }
    while (end > s && isspace((unsigned char)*(end - 1))) {
        end--;
    }
    return (end > s) ? strndup(s, (size_t)(end - s)) : NULL;
}

/* Format ISO 8601 timestamp with timezone offset, e.g.
 * "2024-01-15T10:30:00.000+05:30".  Returns a strdup'd string or NULL. */
static char *
format_iso8601(time_t t, int offset_minutes)
{
    struct tm tm_utc;
    char      datebuf[32];
    char      outbuf[64];

    time_t adjusted = t + (time_t)offset_minutes * 60;
    if (!gmtime_r(&adjusted, &tm_utc)) {
        return NULL;
    }
    if (!strftime(datebuf, sizeof(datebuf), "%Y-%m-%dT%H:%M:%S", &tm_utc)) {
        return NULL;
    }
    int  off  = offset_minutes;
    char sign = '+';
    if (off < 0) {
        sign = '-';
        off  = -off;
    }
    snprintf(outbuf, sizeof(outbuf), "%s.000%c%02d:%02d",
             datebuf, sign, off / 60, off % 60);
    return strdup(outbuf);
}

/* "Name <email>" from a git_signature.  Returns malloc'd string or NULL. */
static char *
signature_person(const git_signature *sig)
{
    if (!sig || !sig->name || !sig->email) {
        return NULL;
    }
    size_t len = strlen(sig->name) + strlen(sig->email) + 4; /* " <>\0" */
    char  *out = malloc(len);
    if (!out) {
        return NULL;
    }
    snprintf(out, len, "%s <%s>", sig->name, sig->email);
    return out;
}

/* Sanitize a remote URL by stripping embedded credentials.
 * Returns a strdup'd string or NULL. */
static char *
sanitize_origin(const char *url)
{
    if (!url || !*url) {
        return NULL;
    }
    if (strncmp(url, "http://", 7) != 0 && strncmp(url, "https://", 8) != 0) {
        return strdup(url);
    }
    const char *scheme_end = strstr(url, "://");
    if (!scheme_end) {
        return strdup(url);
    }
    const char *auth  = scheme_end + 3;
    const char *slash = strchr(auth, '/');
    /* Search for the LAST '@' in the authority (before the first '/').
     * Using the first '@' leaks credential bytes when a password/token
     * contains a literal '@' character. */
    const char *auth_end = slash ? slash : auth + strlen(auth);
    const char *at       = NULL;
    for (const char *p = auth_end - 1; p >= auth; p--) {
        if (*p == '@') { at = p; break; }
    }
    if (!at) {
        return strdup(url);
    }
    size_t      prefix_len = (size_t)(scheme_end - url) + 3;
    const char *rest       = at + 1;
    size_t      rest_len   = strlen(rest);
    size_t      out_len    = prefix_len + rest_len;
    char       *out        = malloc(out_len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, url, prefix_len);
    memcpy(out + prefix_len, rest, rest_len);
    out[out_len] = '\0';
    return out;
}

/* =========================================================================
 * Tag message helpers.
 * ========================================================================= */

/* Extract the tag message, stripping any GPG signature.
 * Sets *is_signed based on whether a complete PGP block was found.
 * Returns a malloc'd trimmed string, or NULL for blank/empty messages. */
static char *
trim_tag_message(const char *message, bool *is_signed)
{
    *is_signed = false;
    if (!message) {
        return NULL;
    }
    const char *sig_start = strstr(message, gpg_sig_start);
    const char *sig_end   = sig_start ? strstr(sig_start, gpg_sig_end) : NULL;
    if (sig_start && sig_end) {
        *is_signed = true;
        return trim_cstr(message, (size_t)(sig_start - message));
    }
    return trim_cstr(message, strlen(message));
}

/* =========================================================================
 * Remote / origin resolution.
 * ========================================================================= */

static char *
origin_from_remote(git_repository *repo, const char *remote_name)
{
    git_remote *remote = NULL;
    char       *out    = NULL;
    if (!remote_name) {
        return NULL;
    }
    if (git_remote_lookup(&remote, repo, remote_name) < 0) {
        return NULL;
    }
    out = sanitize_origin(git_remote_url(remote));
    git_remote_free(remote);
    return out;
}

static char *
resolve_origin(git_repository *repo, git_reference *head)
{
    git_buf  buf    = GIT_BUF_INIT;
    char    *origin = NULL;

    if (head && git_reference_is_branch(head)) {
        if (git_branch_upstream_remote(&buf, repo, git_reference_name(head)) == 0) {
            origin = origin_from_remote(repo, buf.ptr);
        }
    }
    if (!origin) {
        origin = origin_from_remote(repo, "origin");
    }
    if (!origin) {
        git_strarray remotes = {0};
        if (git_remote_list(&remotes, repo) == 0 && remotes.count > 0) {
            for (size_t i = 0; i < remotes.count; i++) {
                origin = origin_from_remote(repo, remotes.strings[i]);
                if (origin) {
                    break;
                }
            }
        }
        git_strarray_free(&remotes);
    }
    git_buf_dispose(&buf);
    if (!origin) {
        origin = strdup("local");
    }
    return origin;
}

/* =========================================================================
 * Worktree status.
 * ========================================================================= */

static void
set_missing_files(chalk_git_result_t *out, git_repository *repo)
{
    if (git_repository_is_bare(repo)) {
        return;
    }

    git_status_options opts   = GIT_STATUS_OPTIONS_INIT;
    git_status_list   *status = NULL;

    opts.show    = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags  |= GIT_STATUS_OPT_INCLUDE_UNTRACKED;
    opts.flags  |= GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    opts.flags  |= GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX;
    opts.flags  |= GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR;

    if (git_status_list_new(&status, repo, &opts) < 0) {
        CAPTURE_GIT_ERROR(out, error_status, "git_status_list_new failed");
        return;
    }

    str_list_t missing   = {0};
    str_list_t deleted   = {0};
    str_list_t untracked = {0};
    str_list_t modified  = {0};
    size_t     count     = git_status_list_entrycount(status);

    const unsigned int deleted_flags   = GIT_STATUS_WT_DELETED;
    const unsigned int untracked_flags = GIT_STATUS_WT_NEW;
    const unsigned int modified_flags
        = GIT_STATUS_WT_MODIFIED   | GIT_STATUS_INDEX_MODIFIED
        | GIT_STATUS_WT_RENAMED    | GIT_STATUS_INDEX_RENAMED
        | GIT_STATUS_WT_TYPECHANGE | GIT_STATUS_INDEX_TYPECHANGE;

    for (size_t i = 0; i < count; i++) {
        const git_status_entry *entry = git_status_byindex(status, i);
        const char             *path  = NULL;
        if (!entry) {
            continue;
        }

        if (entry->status & deleted_flags) {
            if (entry->index_to_workdir && entry->index_to_workdir->new_file.path) {
                path = entry->index_to_workdir->new_file.path;
            }
            else if (entry->head_to_index && entry->head_to_index->old_file.path) {
                path = entry->head_to_index->old_file.path;
            }
            if (path && *path) {
                str_list_append(&missing, path);
                str_list_append(&deleted, path);
            }
        }

        if (entry->status & untracked_flags) {
            path = NULL;
            if (entry->index_to_workdir && entry->index_to_workdir->new_file.path) {
                path = entry->index_to_workdir->new_file.path;
            }
            if (path && *path) {
                str_list_append(&untracked, path);
            }
        }

        if (entry->status & modified_flags) {
            path = NULL;
            if (entry->index_to_workdir && entry->index_to_workdir->new_file.path) {
                path = entry->index_to_workdir->new_file.path;
            }
            else if (entry->head_to_index && entry->head_to_index->new_file.path) {
                path = entry->head_to_index->new_file.path;
            }
            else if (entry->head_to_index && entry->head_to_index->old_file.path) {
                path = entry->head_to_index->old_file.path;
            }
            if (path && *path) {
                str_list_append(&modified, path);
            }
        }
    }

    git_status_list_free(status);

    out->vcs_missing_files   = str_list_finish(&missing);
    out->vcs_deleted_files   = str_list_finish(&deleted);
    out->vcs_untracked_files = str_list_finish(&untracked);
    out->vcs_modified_files  = str_list_finish(&modified);
}

/* =========================================================================
 * Diff stats and patch.
 * ========================================================================= */

static void
set_diff_stat(chalk_git_result_t *out, git_repository *repo,
              git_commit *commit, bool want_patch)
{
    git_tree       *tree  = NULL;
    git_diff       *diff  = NULL;
    git_diff_stats *stats = NULL;

    if (!repo || !commit || git_repository_is_bare(repo)) {
        return;
    }
    if (git_commit_tree(&tree, commit) < 0) {
        CAPTURE_GIT_ERROR(out, error_diff, "git_commit_tree failed");
        goto cleanup;
    }

    git_diff_options diff_opts = GIT_DIFF_OPTIONS_INIT;
    if (git_diff_tree_to_workdir_with_index(&diff, repo, tree, &diff_opts) < 0) {
        CAPTURE_GIT_ERROR(out, error_diff, "git_diff_tree_to_workdir_with_index failed");
        goto cleanup;
    }
    if (git_diff_get_stats(&stats, diff) < 0) {
        CAPTURE_GIT_ERROR(out, error_diff, "git_diff_get_stats failed");
        goto cleanup;
    }

    out->diff_stat_files      = (int64_t)git_diff_stats_files_changed(stats);
    out->diff_stat_insertions = (int64_t)git_diff_stats_insertions(stats);
    out->diff_stat_deletions  = (int64_t)git_diff_stats_deletions(stats);

    if (want_patch) {
        git_buf patch = GIT_BUF_INIT;
        if (git_diff_to_buf(&patch, diff, GIT_DIFF_FORMAT_PATCH) == 0
            && patch.ptr && patch.size > 0)
        {
            out->diff_patch = strndup(patch.ptr, patch.size);
        }
        git_buf_dispose(&patch);
    }

cleanup:
    if (stats) { git_diff_stats_free(stats); }
    if (diff)  { git_diff_free(diff); }
    if (tree)  { git_tree_free(tree); }
}

/* =========================================================================
 * Tag selection.
 * ========================================================================= */

typedef struct {
    bool    has_value;
    bool    signed_tag;
    bool    annotated;
    char   *name;     /* strdup'd */
    char   *tagger;   /* strdup'd, NULL for lightweight */
    char   *message;  /* strdup'd, NULL for lightweight */
    char   *date;     /* strdup'd ISO 8601, NULL for lightweight */
    int64_t timestamp_ms;
} best_tag_t;

static bool
tag_is_better(const best_tag_t *best, int64_t ts_ms, const char *name)
{
    if (!best->has_value) {
        return true;
    }
    if (ts_ms > best->timestamp_ms) {
        return true;
    }
    if (ts_ms < best->timestamp_ms) {
        return false;
    }
    if (!best->name) {
        return true;
    }
    return strcmp(name, best->name) > 0;
}

static void
consider_tag(best_tag_t *best, const char *name, int64_t ts_ms,
             bool signed_tag, bool annotated,
             const char *tagger, const char *message, const char *date)
{
    if (!tag_is_better(best, ts_ms, name)) {
        return;
    }
    free(best->name);
    free(best->tagger);
    free(best->message);
    free(best->date);
    best->has_value    = true;
    best->name         = strdup(name);
    best->tagger       = tagger  ? strdup(tagger)  : NULL;
    best->message      = message ? strdup(message) : NULL;
    best->date         = date    ? strdup(date)    : NULL;
    best->timestamp_ms = ts_ms;
    best->signed_tag   = signed_tag;
    best->annotated    = annotated;
}

static void select_latest_tag(best_tag_t *best, chalk_git_result_t *out,
                               git_repository *repo, const git_oid *head_oid);

/* =========================================================================
 * Lightweight-tag refetch.
 * ========================================================================= */

static git_remote *
resolve_remote_for_fetch(git_repository *repo, git_reference *head)
{
    git_remote *remote = NULL;
    git_buf     buf    = GIT_BUF_INIT;

    if (head && git_reference_is_branch(head)) {
        if (git_branch_upstream_remote(&buf, repo, git_reference_name(head)) == 0) {
            if (git_remote_lookup(&remote, repo, buf.ptr) == 0) {
                goto done;
            }
        }
    }
    if (!remote && git_remote_lookup(&remote, repo, "origin") == 0) {
        goto done;
    }
    if (!remote) {
        git_strarray remotes = {0};
        if (git_remote_list(&remotes, repo) == 0 && remotes.count > 0) {
            for (size_t i = 0; i < remotes.count; i++) {
                if (git_remote_lookup(&remote, repo, remotes.strings[i]) == 0) {
                    break;
                }
            }
        }
        git_strarray_free(&remotes);
    }
done:
    git_buf_dispose(&buf);
    return remote;
}

/* Refetch every lightweight tag that points to head_oid from the remote,
 * then re-run select_latest_tag so signed/annotated remote tags win over
 * the stub lightweight refs created by tools like the GitHub Actions
 * checkout action. */
static void
refetch_lightweight_tags_on_head(chalk_git_result_t *out,
                                  git_repository *repo, git_reference *head,
                                  const git_oid *head_oid,
                                  int connect_timeout_ms, int transfer_timeout_ms)
{
    git_strarray  tag_names = {0};
    git_remote   *remote    = NULL;
    char        **to_fetch  = NULL;
    size_t        n_fetch   = 0;

    if (git_tag_list(&tag_names, repo) < 0) {
        return;
    }

    to_fetch = calloc(tag_names.count, sizeof(char *));
    if (!to_fetch) {
        git_strarray_free(&tag_names);
        return;
    }

    for (size_t i = 0; i < tag_names.count; i++) {
        const char    *name    = tag_names.strings[i];
        git_reference *ref     = NULL;
        git_object    *obj     = NULL;
        git_object    *peeled  = NULL;

        if (!name) {
            continue;
        }

        size_t ref_name_len = strlen("refs/tags/") + strlen(name) + 1;
        char  *ref_name     = malloc(ref_name_len);
        if (!ref_name) {
            continue;
        }
        snprintf(ref_name, ref_name_len, "refs/tags/%s", name);

        if (git_reference_lookup(&ref, repo, ref_name) < 0) {
            free(ref_name);
            continue;
        }
        free(ref_name);

        if (git_reference_peel(&peeled, ref, GIT_OBJECT_COMMIT) < 0 ||
            git_oid_cmp(git_object_id(peeled), head_oid) != 0) {
            git_object_free(peeled);
            git_reference_free(ref);
            continue;
        }
        git_object_free(peeled);

        const git_oid *target_oid = git_reference_target(ref);
        if (target_oid &&
            git_object_lookup(&obj, repo, target_oid, GIT_OBJECT_ANY) == 0) {
            if (git_object_type(obj) == GIT_OBJECT_COMMIT) {
                to_fetch[n_fetch++] = strdup(name);
            }
            git_object_free(obj);
        }
        git_reference_free(ref);
    }
    git_strarray_free(&tag_names);

    if (n_fetch == 0) {
        free(to_fetch);
        return;
    }

    remote = resolve_remote_for_fetch(repo, head);
    if (!remote) {
        for (size_t i = 0; i < n_fetch; i++) {
            free(to_fetch[i]);
        }
        free(to_fetch);
        return;
    }

    if (connect_timeout_ms > 0) {
        git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, connect_timeout_ms);
    }
    if (transfer_timeout_ms > 0) {
        git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, transfer_timeout_ms);
    }

    for (size_t i = 0; i < n_fetch; i++) {
        const char *name       = to_fetch[i];
        size_t      refspec_len = strlen(name) * 2 + strlen("+refs/tags/:refs/tags/") + 1;
        char       *refspec    = malloc(refspec_len);
        if (!refspec) {
            continue;
        }
        snprintf(refspec, refspec_len, "+refs/tags/%s:refs/tags/%s", name, name);

        char            *specs[]  = {refspec};
        git_strarray     refspecs = {specs, 1};
        git_fetch_options opts    = GIT_FETCH_OPTIONS_INIT;
        opts.download_tags        = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
        if (git_remote_fetch(remote, &refspecs, &opts, NULL) < 0) {
            CAPTURE_GIT_ERROR(out, error_tag, "git_remote_fetch failed");
        }
        free(refspec);
    }

    git_remote_free(remote);
    for (size_t i = 0; i < n_fetch; i++) {
        free(to_fetch[i]);
    }
    free(to_fetch);
}

/* =========================================================================
 * Tag iteration.
 * ========================================================================= */

static void
select_latest_tag(best_tag_t *best, chalk_git_result_t *out,
                  git_repository *repo, const git_oid *head_oid)
{
    git_strarray tag_names = {0};
    if (git_tag_list(&tag_names, repo) < 0) {
        CAPTURE_GIT_ERROR(out, error_tag, "git_tag_list failed");
        return;
    }

    for (size_t i = 0; i < tag_names.count; i++) {
        const char    *tag_name = tag_names.strings[i];
        git_reference *ref      = NULL;
        git_object    *obj      = NULL;
        git_object    *peeled   = NULL;

        if (!tag_name) {
            continue;
        }

        size_t ref_len  = strlen("refs/tags/") + strlen(tag_name) + 1;
        char  *ref_name = malloc(ref_len);
        if (!ref_name) {
            continue;
        }
        snprintf(ref_name, ref_len, "refs/tags/%s", tag_name);

        if (git_reference_lookup(&ref, repo, ref_name) < 0) {
            free(ref_name);
            continue;
        }
        free(ref_name);

        if (git_reference_peel(&peeled, ref, GIT_OBJECT_COMMIT) < 0) {
            git_reference_free(ref);
            continue;
        }

        const git_oid *target_oid = git_object_id(peeled);
        if (!target_oid || git_oid_cmp(target_oid, head_oid) != 0) {
            git_object_free(peeled);
            git_reference_free(ref);
            continue;
        }

        {
            const git_oid *ref_target = git_reference_target(ref);
            if (!ref_target ||
                git_object_lookup(&obj, repo, ref_target, GIT_OBJECT_ANY) < 0)
            {
                git_object_free(peeled);
                git_reference_free(ref);
                continue;
            }
        }

        if (git_object_type(obj) == GIT_OBJECT_TAG) {
            git_tag *tag = NULL;
            if (git_tag_lookup(&tag, repo, git_object_id(obj)) == 0) {
                const git_signature *tagger_sig = git_tag_tagger(tag);
                char   *tagger_str   = NULL;
                char   *tag_date_str = NULL;
                int64_t ts_ms        = 0;

                if (tagger_sig) {
                    tagger_str   = signature_person(tagger_sig);
                    tag_date_str = format_iso8601((time_t)tagger_sig->when.time,
                                                  (int)tagger_sig->when.offset);
                    ts_ms        = (int64_t)tagger_sig->when.time * 1000;
                }

                bool  is_signed  = false;
                char *msg_str    = trim_tag_message(git_tag_message(tag),
                                                    &is_signed);

                consider_tag(best, tag_name, ts_ms, is_signed, true,
                             tagger_str, msg_str, tag_date_str);

                free(tagger_str);
                free(tag_date_str);
                free(msg_str);
                git_tag_free(tag);
            }
        }
        else if (git_object_type(obj) == GIT_OBJECT_COMMIT) {
            consider_tag(best, tag_name, 0, false, false, NULL, NULL, NULL);
        }

        git_object_free(obj);
        git_object_free(peeled);
        git_reference_free(ref);
    }

    git_strarray_free(&tag_names);
}

/* =========================================================================
 * Public API.
 * ========================================================================= */

void
chalk_git_result_free(chalk_git_result_t *r)
{
    if (!r) {
        return;
    }
    free(r->commit_id);
    free(r->author);
    free(r->committer);
    free(r->commit_message);
    free(r->branch);
    free(r->origin_uri);
    free(r->vcs_dir);
    free(r->date_authored);
    free(r->date_committed);
    free(r->tag);
    free(r->tagger);
    free(r->tag_message);
    free(r->date_tagged);
    free(r->diff_patch);
    free(r->error_commit);
    free(r->error_tag);
    free(r->error_status);
    free(r->error_diff);

    if (r->vcs_missing_files) {
        for (size_t i = 0; r->vcs_missing_files[i]; i++) {
            free(r->vcs_missing_files[i]);
        }
        free(r->vcs_missing_files);
    }
    if (r->vcs_deleted_files) {
        for (size_t i = 0; r->vcs_deleted_files[i]; i++) {
            free(r->vcs_deleted_files[i]);
        }
        free(r->vcs_deleted_files);
    }
    if (r->vcs_modified_files) {
        for (size_t i = 0; r->vcs_modified_files[i]; i++) {
            free(r->vcs_modified_files[i]);
        }
        free(r->vcs_modified_files);
    }
    if (r->vcs_untracked_files) {
        for (size_t i = 0; r->vcs_untracked_files[i]; i++) {
            free(r->vcs_untracked_files[i]);
        }
        free(r->vcs_untracked_files);
    }
    free(r);
}

char *
chalk_git_discover_worktree(char *path)
{
    git_buf         buf    = GIT_BUF_INIT;
    git_repository *repo   = NULL;
    char           *result = NULL;

    git_libgit2_init();
    git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, 0);
    if (git_repository_discover(&buf, path, 0, NULL) < 0) {
        goto done;
    }
    if (git_repository_open(&repo, buf.ptr) < 0) {
        goto done;
    }
    {
        const char *workdir = git_repository_workdir(repo);
        const char *gitdir  = git_repository_path(repo);
        result = strdup_rtrim_slash(workdir ? workdir : gitdir);
    }
done:
    git_buf_dispose(&buf);
    if (repo) { git_repository_free(repo); }
    return result;
}

chalk_git_result_t *
chalk_git_collect(char *repo_root, bool worktree_status,
                  bool diff_stat, bool diff_patch,
                  bool collect_tags, bool refetch_tags,
                  int connect_timeout_ms, int transfer_timeout_ms,
                  char *chalk_cert_path)
{
    chalk_git_result_t *result   = calloc(1, sizeof(chalk_git_result_t));
    git_repository     *repo     = NULL;
    git_reference      *head     = NULL;
    git_object         *head_obj = NULL;
    git_commit         *commit   = NULL;
    best_tag_t          best_tag = {0};
    char                oidstr[GIT_OID_SHA1_HEXSIZE + 1];

    if (!result || !repo_root || !*repo_root) {
        return result;
    }

    git_libgit2_init();
    git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, 0);
    if (collect_tags && refetch_tags) {
        setup_ssl_certs(result, chalk_cert_path);
    }

    if (git_repository_open(&repo, repo_root) < 0) {
        CAPTURE_GIT_ERROR(result, error_commit, "git_repository_open failed");
        goto cleanup;
    }

    if (git_repository_head(&head, repo) < 0) {
        CAPTURE_GIT_ERROR(result, error_commit, "git_repository_head failed");
        if (worktree_status) {
            set_missing_files(result, repo);
        }
        goto cleanup;
    }

    /* BRANCH */
    if (git_reference_is_branch(head)) {
        const char *branch = NULL;
        if (git_branch_name(&branch, head) == 0 && branch) {
            result->branch = strdup(branch);
        }
    }

    /* ORIGIN_URI */
    result->origin_uri = resolve_origin(repo, head);

    if (git_reference_peel(&head_obj, head, GIT_OBJECT_COMMIT) < 0) {
        CAPTURE_GIT_ERROR(result, error_commit, "git_reference_peel failed");
        if (worktree_status) {
            set_missing_files(result, repo);
        }
        goto cleanup;
    }

    commit = (git_commit *)head_obj;

    /* VCS_DIR_WHEN_CHALKED */
    {
        const char *workdir = git_repository_workdir(repo);
        if (workdir && *workdir) {
            result->vcs_dir = strdup_rtrim_slash(workdir);
        }
        else {
            const char *gitdir = git_repository_path(repo);
            if (gitdir && *gitdir) {
                char *d = strdup_rtrim_slash(gitdir);
                result->vcs_dir = parent_dir_str(d);
                free(d);
            }
        }
    }

    /* COMMIT_ID */
    git_oid_tostr(oidstr, sizeof(oidstr), git_commit_id(commit));
    result->commit_id = strdup(oidstr);

    /* COMMIT_SIGNED */
    {
        git_buf sig  = GIT_BUF_INIT;
        git_buf data = GIT_BUF_INIT;
        result->commit_signed
            = (git_commit_extract_signature(&sig, &data, repo,
                                            (git_oid *)git_commit_id(commit),
                                            NULL)
               == 0);
        git_buf_dispose(&sig);
        git_buf_dispose(&data);
    }

    /* AUTHOR */
    {
        const git_signature *author = git_commit_author(commit);
        result->author = signature_person(author);
        if (author && result->author) {
            result->date_authored      = format_iso8601((time_t)author->when.time,
                                                         (int)author->when.offset);
            result->timestamp_authored = (int64_t)author->when.time * 1000;
        }
    }

    /* COMMITTER */
    {
        const git_signature *committer = git_commit_committer(commit);
        result->committer = signature_person(committer);
        if (committer && result->committer) {
            result->date_committed      = format_iso8601((time_t)committer->when.time,
                                                          (int)committer->when.offset);
            result->timestamp_committed = (int64_t)committer->when.time * 1000;
        }
    }

    /* COMMIT_MESSAGE */
    {
        const char *msg = git_commit_message(commit);
        if (msg) {
            result->commit_message = trim_cstr(msg, strlen(msg));
        }
    }

    if (worktree_status) {
        set_missing_files(result, repo);
    }
    if (diff_stat || diff_patch) {
        set_diff_stat(result, repo, commit, diff_patch);
    }

    /* Tags */
    if (collect_tags) {
        if (refetch_tags) {
            refetch_lightweight_tags_on_head(
              result, repo, head, git_commit_id(commit),
              connect_timeout_ms, transfer_timeout_ms);
        }
        select_latest_tag(&best_tag, result, repo, git_commit_id(commit));
    }

    if (best_tag.has_value) {
        /* Transfer ownership to result — do not free best_tag fields. */
        result->tag            = best_tag.name;
        result->tag_signed     = best_tag.signed_tag;
        result->tagger         = best_tag.tagger;
        result->tag_message    = best_tag.message;
        result->date_tagged    = best_tag.date;
        result->timestamp_tagged = best_tag.timestamp_ms;
        best_tag = (best_tag_t){0}; /* zero to prevent double-free in cleanup */
    }

cleanup:
    free(best_tag.name);
    free(best_tag.tagger);
    free(best_tag.message);
    free(best_tag.date);

    if (head_obj) { git_object_free(head_obj); }
    if (head)     { git_reference_free(head); }
    if (repo)     { git_repository_free(repo); }
    git_libgit2_shutdown();
    return result;
}
