# Design: Docker Registry Integration

This document describes how Chalk integrates with Docker registries to
push additional images and upload build contexts as OCI attestations.

## Overview

Chalk can be configured to push Docker images to additional registries
and repositories beyond those in the original `docker build` or
`docker push` command. Additionally, Chalk can upload the Docker build
context as an OCI artifact attached to the image, enabling downstream
tools such as Ocular to scan both the built image and the exact sources
used to produce it.

## Additional Docker Pushes (`docker_push`)

### Configuration

The `docker_registry` singleton and `docker_push` object sections in
the Chalk configuration control registry-level and push-level settings.

```con4m
docker {
  docker_registry my_registry {
    uri:          "registry.example.com"
    enabled:      true
    login_method: "get"
    docker_login_get {
      uri: "https://auth.example.com/v1/docker-creds"
    }
    docker_push my_app {
      enabled:    true
      repository: "my-org/my-app"
      tags:       ["latest", "{BRANCH}"]
      docker_context_upload {
        enabled:  true
        strategy: "auto"
      }
    }
  }
}
```

Each named `docker_push` section inside a `docker_registry` section
defines a repository and tag set to mirror the built image to.

**`docker_push` fields:**

| Field        | Type           | Default    | Description                                 |
| ------------ | -------------- | ---------- | ------------------------------------------- |
| `enabled`    | `bool`         | `true`     | Enable or disable this push configuration   |
| `repository` | `string`       | (required) | Repository path within the parent registry  |
| `tags`       | `list[string]` | (required) | Tags to push; supports `{KEY}` substitution |

Build context upload is configured in a nested `docker_context_upload`
singleton. Its presence enables upload; omitting it disables upload for
that push target.

**`docker_context_upload` fields:**

| Field                | Type           | Default     | Description                                                           |
| -------------------- | -------------- | ----------- | --------------------------------------------------------------------- |
| `enabled`            | `bool`         | `false`     | Set to `true` to activate context upload                              |
| `mode`               | `string`       | `"full"`    | Context upload mode; only `"full"` is supported                       |
| `strategy`           | `string`       | `"auto"`    | Strategy for context upload (see below)                               |
| `size_threshold`     | `Size`         | `<<100mb>>` | Skip upload when tarball exceeds this size (0 = no limit)             |
| `max_file_size`      | `Size`         | `<<0mb>>`   | Skip individual files larger than this size in the tarball (0 = none) |
| `exclude_patterns`   | `list[string]` | `[".git"]`  | Glob patterns to exclude from the context tarball                     |
| `honor_dockerignore` | `bool`         | `true`      | Apply `.dockerignore` patterns when creating the tarball              |

### Tag Template Substitution

Tag values support `{KEY}` template substitution using any chalk-time
key. Key names are case-insensitive. Any characters in the rendered
value that are not alphanumeric, `.`, `_`, or `-` are replaced with
`-` to produce a valid Docker tag.

Examples:

- `"v{TAG}"` -> `"v1.2.3"` (if `TAG` key is `"1.2.3"`)
- `"{BRANCH}-latest"` -> `"main-latest"` (if `BRANCH` key is `"main"`)
- `"{COMMIT_ID}"` -> first 12 characters of the git commit SHA

Tags with empty substitution results are skipped.

### Behavior During `chalk docker build`

When `tags` is non-empty and the original build has no explicit `-t`
flags, Chalk appends `--output type=image,push=true,name=<image>` to
the build arguments to push directly from the BuildKit cache. When
explicit tags are present in the original command, Chalk appends `-t
<image>` for each configured tag and runs `docker push` after the
build. Any tags added solely by Chalk are pruned locally after the
build completes.

### Behavior During `chalk docker push`

After the original push command succeeds, Chalk retags the image for
each configured tag and runs `docker push` on each one. Locally-created
tags are pruned once all pushes finish.

## Build Context Upload

Chalk can upload Docker build contexts as OCI artifacts in the same
registry and repository as the pushed image. This enables tools like
Ocular to inspect the exact build inputs along with the resulting image.

Both the main build context (the directory argument to `docker build`)
and any named extra contexts added via `--build-context name=path` are
uploaded, as long as they point to local directories. Non-directory
contexts (Git URLs, `oci-layout://`, `docker-image://`) are skipped.

### OCI Representation

The context is packaged as a `.tar.gz` archive and attached to the
image as an OCI image manifest stored at the attestation tag:

```
<registry>/<repo>:sha256-<image-manifest-digest>
```

The manifest has:

- `artifactType`: `application/vnd.crashoverride.chalk.build-context.v1`
- `config.mediaType`: `application/vnd.oci.empty.v1+json`
- one layer with `mediaType`: `application/vnd.oci.image.layer.v1.tar+gzip`
- `subject`: the image manifest descriptor (registry-resolved)
- `annotations`:
  - `org.opencontainers.image.created` — RFC3339 timestamp of the upload
  - `dev.crashoverride.chalk.build-context.name` — context name (`"."` for
    the main context, the declared name for `--build-context` extras)

The same annotations appear on the manifest's descriptor entry inside the
attestation manifest list, allowing consumers to identify and select the
correct entry without fetching each manifest individually.

Multiple attestation manifests for the same image (e.g., a sigstore
signature and a build context) are stored in a manifest list at the
same `sha256-<digest>` tag. Chalk fetches any existing manifest list
before appending to it, so multiple attestation types coexist without
overwriting each other.

`_REPO_BUILD_CONTEXTS` stores the digest of the **context image manifest**
itself (the entry with `artifactType: application/vnd.crashoverride.chalk.build-context.v1`),
not the digest of the enclosing manifest list. Consumers can fetch the
context manifest directly without resolving through the list.

### Upload Strategies

Because `chalk docker build` and `chalk docker push` can run as
separate commands, the timing of the context upload is configurable
via `upload_context_strategy`:

| Strategy   | Build time                                 | Push time                                          |
| ---------- | ------------------------------------------ | -------------------------------------------------- |
| `registry` | Upload blob to target registry             | Create and push attestation manifest               |
| `local`    | Save `.tar.gz` to `/tmp`                   | Upload blob + push attestation manifest            |
| `disk`     | Record context path in chalk mark          | Read path, create `.tar.gz`, upload, push manifest |
| `auto`     | CI detected -> `registry`; else -> `local` | (see above)                                        |

**`registry` strategy** is best for CI environments where the build
host has network access to the target registry. The tarball is created
and the blob uploaded during `chalk docker build`, so the blob is
already in the registry when `chalk docker push` runs. Only the
manifest creation is deferred to push time.

**`local` strategy** is the default for non-CI environments. CI is detected
by the presence of any of the following environment variables: `CI`,
`GITHUB_ACTIONS`, `GITLAB_CI`, `JENKINS_URL`, `CIRCLECI`, `TRAVIS`,
`BUILDKITE`, `DRONE`, `SEMAPHORE`, `TEAMCITY_VERSION`,
`BITBUCKET_BUILD_NUMBER`, `CODEBUILD_BUILD_ID`. The
tarball is written to a date-stamped subdirectory under
`<tmpdir>/chalk-build-contexts/` and uploaded at push time. This
avoids requiring registry credentials at build time.

**`disk` strategy** reads the context directory from disk at push
time. This is suitable for single-machine workflows where the context
directory has not changed between build and push. Users who choose
this strategy accept the risk that the context may differ from what
was actually used in the build.

### Context Filtering

When creating the `.tar.gz` archive, Chalk applies an ordered list of glob
patterns to decide which files and directories to include. Two sources of
patterns are combined:

1. **`.dockerignore`** - read from the root of the build context when
   `upload_context_honor_dockerignore` is `true` (the default). This ensures
   the uploaded context matches what Docker itself would have used.
2. **`upload_context_exclude_patterns`** - explicitly configured patterns,
   applied after `.dockerignore` so they take final precedence (default
   `[".git"]`).

Because patterns are evaluated in order with **last-match-wins** semantics, the
chalk configuration always has the final say over what is included or excluded.

When a directory matches an exclusion pattern, Chalk still recurses into it so
that negation patterns can re-include individual files inside it. For example,
`logs/` excludes the directory entry itself but a later `!logs/*.log` can still
re-include matching files within it. Only the directory header is suppressed;
recursion is unconditional.

#### Pattern syntax

Patterns follow the same rules as `.dockerignore` and `tar --exclude`:

| Syntax | Meaning                                               |
| ------ | ----------------------------------------------------- |
| `*`    | Any sequence of characters except `/`                 |
| `?`    | Any single character except `/`                       |
| `**`   | Any sequence of characters including `/` (path cross) |
| `!pat` | Negate: re-include files matched by a previous rule   |

Patterns **without** a `/` are matched against every path component
individually (so `.git` excludes any directory named `.git` at any depth).
Patterns **with** a `/` are matched against the full path relative to the
context root.

Leading `/` characters are stripped from patterns read from `.dockerignore`
since all paths are relative to the context root. Blank lines and lines
beginning with `#` are ignored.

#### Precedence example

Given `.dockerignore`:

```
logs/
!logs/important.log
```

And `upload_context_exclude_patterns: ["*.tmp", "!keep.tmp"]`, the effective
pattern list is:

```
logs/              # from .dockerignore - excludes logs/ directory
!logs/important.log  # from .dockerignore - re-includes one file
*.tmp              # from chalk config - excludes .tmp files
!keep.tmp          # from chalk config - re-includes keep.tmp
```

Because chalk config patterns come last, `!keep.tmp` overrides any earlier
exclusion of `keep.tmp`, and `*.tmp` overrides `.dockerignore` rules for
`.tmp` files.

### Size Threshold

When `upload_context_size_threshold` is set (default `100mb`), Chalk measures
the `.tar.gz` tarball after it is created and skips the upload if the size
exceeds the threshold. The failure is recorded in `_OP_FAILED_KEYS` under the
key `_REPO_BUILD_CONTEXTS` with code `CONTEXT_TOO_LARGE`, including the context
name, path, actual size, and configured threshold.

For the `registry` and `local` strategies the check runs at build time
immediately after the tarball is created. For the `disk` strategy the threshold
is stored in the chalk mark snapshot and checked at push time when the tarball
is created. Setting the threshold to `0` disables the check entirely.

### Context Cache and Cleanup

For the `local` strategy, Chalk stores tarballs in a datetime-stamped
directory structure:

```
/tmp/chalk-build-contexts/
  2025-01-15T14-32-07/
    myapp-1736956800.tar.gz
  2025-01-15T09-10-45/
    ...
```

Old entries are removed when the age exceeds
`docker.build_context_cache_max_age` (a `Duration` value, default 1
hour). Cleanup runs automatically at build time before creating new
tarballs.

**Configuration:**

```con4m
docker {
  build_context_cache_max_age: <<1 hrs>>
}
```

### Intermediate State

When build and push are separate commands, Chalk stores intermediate
context upload state in the `DOCKER_BUILD_CONTEXT_SNAPSHOTS` chalk-time
key embedded in the image's chalk mark. The structure mirrors
`_REPO_BUILD_CONTEXTS`: `registry -> repo -> context name -> config`.

The context name is `"."` for the main build context and the declared
name for each `--build-context` extra. The per-context config object
carries strategy-specific fields:

| Strategy   | Fields                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------- |
| `registry` | `strategy`, `blob_digest`, `blob_size`                                                                  |
| `local`    | `strategy`, `tar_path`                                                                                  |
| `disk`     | `strategy`, `context_path`, `size_threshold`, `exclude_patterns`, `honor_dockerignore`, `max_file_size` |

At push time, Chalk reads this key from the image's chalk mark and
completes the attestation manifest creation.

### Chalk Keys

| Key                              | Kind       | Type                                                          | Description                                                                                                 |
| -------------------------------- | ---------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `DOCKER_BUILD_CONTEXT_SNAPSHOTS` | chalk-time | `dict[string, dict[string, dict[string, dict[string, \`x]]]]` | Intermediate upload state: `registry -> repo -> context name -> strategy config`                            |
| `_REPO_BUILD_CONTEXTS`           | runtime    | `dict[string, dict[string, dict[string, string]]}`            | Context manifest digests: `registry -> repo -> context name -> context manifest digest (no sha256: prefix)` |

### Limitations

- Only local directory contexts are supported. Git URL contexts
  (`https://github.com/...`) are intentionally skipped: the content is
  already captured in git state, so uploading would be redundant. The
  primary use-case is uploading contexts that may have been mutated
  relative to git (local directories). `oci-layout://` and
  `docker-image://` references are also skipped.
- The `full` mode is the only supported `upload_context_mode`; future
  modes may support filtered or diff-only uploads.
- Multi-platform builds upload all contexts once (on the base chalk
  object before per-platform copies are made); each platform image then
  references the same pre-uploaded blobs at push time.
- The `disk` strategy does not verify context integrity; the uploaded
  content may differ from the build-time context if the directory was
  mutated between build and push.

## Registry Authentication

Registry authentication for both additional pushes and context upload
uses the same Docker credential store that the Docker daemon uses, read
from `~/.docker/config.json`. The `docker_registry` login methods
(`""`, `"get"`) configure how Chalk fetches or refreshes credentials
before registry operations.

## Relationship to Sigstore Attestations

Both the sigstore chalk attestation (from `chalk setup`) and the build
context attestation use the same OCI manifest list at the
`sha256-<digest>` tag. They coexist without conflict: Chalk reads the
existing list before appending a new entry, so no data is overwritten.
The shared utility `appendToAttestationManifestList` in
`src/docker/manifest.nim` handles this fetch-or-create-then-append
pattern for both use cases.
