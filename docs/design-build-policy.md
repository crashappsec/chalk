# Design: Build Policies

Chalk can evaluate build policies when it wraps `docker build` and
`docker push`, and either report or block builds that violate them. The first
supported policy restricts which base images a build may use ("golden
images").

## Opt-in

Build policies are disabled by default. With the default configuration
(`policy.mode = "off"`):

- no policy is evaluated and no registry or chalk mark lookups are made for
  policies;
- nothing is published to the `policy` topic;
- the `_POLICY_*` keys are never collected, so existing reports are unchanged;
- `chalk docker` behaves exactly as before, including falling back to running
  docker without chalk when chalk itself fails.

Policies only take effect once `policy.mode` is set to `audit` or `enforce`,
or `policy.enforce_repos` lists repositories in which to enforce them (see
[Per-repository enforcement](#per-repository-enforcement)).

## Motivation

Chalk already sits in front of every wrapped `docker build` and knows the
exact images a build pulls in. That makes it a natural place for simple
organizational guardrails, such as "only build on top of approved base
images", without changing how developers invoke docker.

## Modes

| Mode      | Evaluates | Policy report on violation | Fails the command |
| --------- | --------- | -------------------------- | ----------------- |
| `off`     | no        | no                         | no                |
| `audit`   | yes       | yes                        | no                |
| `enforce` | yes       | yes                        | yes (exit 1)      |

`mode` applies to every repository unless `enforce_repos` enforces the policy
in some of them, see [Per-repository enforcement](#per-repository-enforcement).

A policy report is published only when there is at least one violation or an
evaluation error. Builds that pass all policies publish nothing extra.

When a policy cannot reach a decision (for example an image digest could not
be resolved, or an allowlist entry uses an unknown kind), `on_error` decides.
The default is `allow`, consistent with chalk's fail-open behavior elsewhere.
Evaluation errors are always reported.

In `enforce` mode a blocked command exits with code 1 before docker runs, so
the image is neither built nor pushed. Unlike other chalk failures, a policy
block never falls back to running docker without chalk. If chalk fails before
policies are evaluated (for example a `FROM` it cannot evaluate), the failure
is reported as an evaluation error and `on_error` decides: `block` stops the
command, `allow` falls back to running docker without chalk as before.

## What is checked

- `chalk docker build`: every external image referenced by a `FROM` in a
  stage the build uses (stages built on other stages are resolved to their
  external base), and every image referenced by `COPY --from=<image>` or
  `RUN --mount=from=<image>` in those stages. As in BuildKit, a stage is used when the target reaches it through
  `FROM`, `COPY --from` or `RUN --mount=from`; other stages are never pulled
  and are not checked. A `RUN --mount` chalk cannot evaluate makes every stage
  count as used and is an evaluation error, as its source could be any image. Without buildx (legacy builder) every stage is checked. Named contexts with
  `docker-image://` sources are checked too, including overrides of `FROM`
  images, `COPY --from` references and whole stages. Context names are
  matched the way BuildKit does (familiar reference without `:latest`), so
  `alpine`, `alpine:latest` and `docker.io/library/alpine` all resolve to an
  `alpine` context. A `FROM` naming a stage defined later in the Dockerfile is
  an external image, as in Docker. Local, Git and HTTP contexts are not
  container images. OCI layout contexts whose image identity cannot be
  determined produce an evaluation error. `FROM scratch` and
  references to other stages of the same Dockerfile are always allowed.
  Policies are evaluated after chalk resolves base image digests and before
  chalk modifies anything (including chalking context files with
  `chalk_contained_items`) or invokes docker, including `--push` builds.
- `chalk docker push`: the base, `COPY --from` and `RUN --mount=from` images
  recorded in the
  image's chalk mark (`DOCKER_BASE_IMAGES`, `DOCKER_COPY_IMAGES`), skipping
  stages recorded with `built` set to `false`. If the image
  is not chalked its base images are unknown, which is an evaluation error
  handled by `on_error`. With `--all-tags`, every local tag in the requested
  repository is checked before any tag is pushed. Findings are combined into
  one policy report. Failure to enumerate tags or read image metadata is an
  evaluation error, also handled by `on_error`.

## Configuration

```con4m
policy {
  mode:     "enforce"     # off | audit | enforce
  on_error: "allow"       # allow | block

  golden_images {
    enabled:         true
    check_copy_from: true
    allowed: [
      ("glob",   "docker.io/library/alpine:*"),
      ("glob",   "cgr.dev/chainguard/*"),
      ("digest", "ghcr.io/acme/base@sha256:0123...")
    ]
    message: "Use an approved golden image: https://example.com/golden"
  }

  # Optional, see "Custom checks" below.
  custom_check: func my_check
}
```

| Field                                  | Type                                              | Default           |
| -------------------------------------- | ------------------------------------------------- | ----------------- |
| `policy.mode`                          | `string`, one of `off`, `audit`, `enforce`        | `"off"`           |
| `policy.id`                            | `string`                                          | `""`              |
| `policy.config_json`                   | `string` (JSON object, see below)                 | `""`              |
| `policy.on_error`                      | `string`, one of `allow`, `block`                 | `"allow"`         |
| `policy.enforce_repos`                 | `list[tuple[string, string]]` (kind, value)       | `[]`              |
| `policy.report_template`               | `string`                                          | `"policy_report"` |
| `policy.custom_check`                  | `func (string, string, string, string) -> string` | unset             |
| `policy.golden_images.enabled`         | `bool`                                            | `false`           |
| `policy.golden_images.check_copy_from` | `bool`                                            | `true`            |
| `policy.golden_images.allowed`         | `list[tuple[string, string]]` (kind, value)       | `[]`              |
| `policy.golden_images.message`         | `string`                                          | `""`              |

With `golden_images.enabled` and an empty `allowed` list, every external
image is a violation.

`policy.id` identifies the policy (e.g. `name@version`). It is reported in
`_POLICY_RESULTS`, as `policy_id` of every finding, and as `_POLICY_ID` when
it is the only policy evaluated.

### JSON configuration

Policies generated by another system can be passed as a single JSON document
via `policy.config_json`, for example from a component parameter. When set, it
replaces every other field of `policy` and `policy.golden_images` except
`report_template` and `custom_check`, which can only be set in con4m. Field
names and types match con4m, with tuples written as arrays:

```json
{
  "id": "golden-images@3",
  "mode": "enforce",
  "on_error": "allow",
  "enforce_repos": [["glob", "github.com/acme/payments"]],
  "golden_images": {
    "enabled": true,
    "check_copy_from": true,
    "allowed": [
      ["glob", "docker.io/library/alpine:*"],
      ["glob", "cgr.dev/chainguard/*"]
    ],
    "message": "Use an approved golden image"
  }
}
```

Missing fields take their defaults. The document is validated strictly: invalid
JSON, unknown fields, wrong types or invalid choices are reported as a single
`config` evaluation error (kind `error`) and no rule runs. The policy keeps the
`mode`, `on_error` and `enforce_repos` it declares when those are themselves
valid, so `on_error` decides as for any other error: an `enforce` policy with
`on_error = "block"` blocks the build, and a policy in mode `off` stays off.
A policy that declares no valid `mode`, like a document that cannot be used as
a whole (not JSON, not an object, an invalid `policies` list), is audited: the error is reported and never blocks. An invalid
`on_error` is `allow`. Only policy settings can be expressed,
so a JSON document can neither change other chalk configuration nor provide
callbacks.

### Several policies

Policies authored and versioned independently (for example several policies
that apply to the same workspace) are passed as a list, each entry with the
same fields as the single-policy document above:

```json
{
  "policies": [
    {
      "id": "golden-images@3",
      "mode": "enforce",
      "golden_images": {
        "enabled": true,
        "allowed": [["glob", "docker.io/library/alpine:*"]]
      }
    },
    {
      "id": "chainguard-only@1",
      "mode": "audit",
      "on_error": "block",
      "golden_images": {
        "enabled": true,
        "check_copy_from": false,
        "allowed": [["glob", "cgr.dev/chainguard/*"]]
      }
    }
  ]
}
```

- Policies are never merged. Each one is evaluated on its own, with its own
  `mode` and `on_error`, against the same images (collected once).
- The command is blocked when any policy blocks it: an `enforce` policy with a
  violation, or with an evaluation error and `on_error = "block"`. `audit`
  policies never block, whatever their `on_error`.
- With more than one entry, every entry needs a non-empty `id` that no other
  entry uses, since results and findings are attributed by `id`.
- An entry that is invalid (not an object, unknown fields, wrong types,
  invalid choices, missing or duplicate `id`) is reported as a `config`
  evaluation error of that entry (`policy_id` is its `id`, when it has a
  string one), which blocks only as the entry's own valid `mode`, `on_error`
  and `enforce_repos` say (see above). The other entries are still evaluated.
  An entry with a duplicate `id` invalidates every entry using that `id`.
- `policies` cannot be combined with other top-level fields; such a document,
  or one whose `policies` is not an array, is invalid as a whole.
- `{"policies": []}` configures no policy, as does a list where every entry is
  in mode `off`.
- `custom_check` is not evaluated with a `policies` list, as a con4m callback
  belongs to none of its entries; chalk logs a warning when one is set.

The single-object form remains supported and behaves as a one-entry list
whose `id` may be empty.

### Per-repository enforcement

To roll out enforcement gradually, a policy can be enforced in some
repositories while `mode` applies everywhere else:

```json
{
  "id": "golden-images@3",
  "mode": "audit",
  "enforce_repos": [
    ["glob", "github.com/acme/payments"],
    ["glob", "github.com/acme/platform-*"]
  ],
  "golden_images": {
    "enabled": true,
    "allowed": [["glob", "cgr.dev/chainguard/*"]]
  }
}
```

`enforce_repos` is available in con4m too (`policy.enforce_repos`, a list of
`(kind, value)` tuples), in the single-policy document and in every entry of
`policies`.

- A command whose repository matches any entry is evaluated in `enforce`
  mode; in every other repository the policy uses `mode`. With `mode: "off"`
  the policy is enforced in the listed repositories and not evaluated
  anywhere else. Without `enforce_repos` (or with an empty list) `mode`
  applies everywhere, as before.
- Entries use the matcher kinds of `golden_images.allowed`. Only `glob`
  applies to repositories; a glob without `*` or `?` matches one repository
  exactly. Entries of other kinds (including `digest`) never match and are
  logged as warnings, so they can never enforce a policy by accident. Values
  are normalized like repositories (see below), so
  `https://github.com/Acme/App.git` and `github.com/acme/app` are equivalent,
  except that glob characters are kept: `github.com/acme/app?` matches
  `github.com/acme/app1`, not `github.com/acme/app`. Only a numeric port is
  removed, so a glob in the port position (`github.com:*/acme/app`) never
  matches.
- An `enforce_repos` that is not a list of `[kind, value]` string pairs makes
  the policy invalid: it is reported as a `config` evaluation error, like any
  other invalid policy, with its `mode` and `on_error` and no `enforce_repos`.
  A valid `enforce_repos` of a policy that is invalid otherwise still applies,
  so the error can block (`on_error = "block"`) in the listed repositories.

The repository is identified as `host/path`, lowercase, without scheme,
credentials, port or `.git` suffix, e.g. `github.com/acme/app` (GitLab
subgroups keep their full path, `gitlab.com/group/sub/app`). SSH
(`git@github.com:acme/app.git`, `ssh://git@github.com:22/acme/app.git`) and
HTTP(S) (`https://token@github.com/acme/app.git`) remotes all normalize to the
same identity. Chalk determines it before docker runs, in this order:

1. for `docker build`, the git remote of the build context: the URL of a git
   context (`docker build https://github.com/acme/app.git#main`), or else the
   origin of the git repository containing the context directory, resolved
   as for `ORIGIN_URI` (the current branch's upstream remote, else `origin`,
   else the first remote). For `docker push`, which has no context, the
   repository containing the working directory. An origin that is a local
   path, including a relative one such as `mirrors/acme/app.git`, identifies
   no repository;
2. otherwise the repository of the CI job: `GITHUB_SERVER_URL` and
   `GITHUB_REPOSITORY` (GitHub Actions, `GITHUB_SERVER_URL` defaulting to
   `https://github.com`), else `CI_PROJECT_URL` (GitLab CI).

Chalk only determines the repository when some policy has `enforce_repos`.
When it cannot be determined (for example a context from stdin or a
directory outside any git repository, outside CI) the policy is never
escalated to `enforce`: it uses `mode` and its `_POLICY_RESULTS` entry has an
empty `repo` and `mode_source` `default`. A warning is logged unless `mode` is
`off`.

As with every policy, this is a guardrail rather than a security boundary:
whoever controls the build can also change the git remote or CI variables.

### Matcher kinds

Image references on both sides are normalized before matching, the same way
docker does (`alpine` → `docker.io/library/alpine:latest`).

- `glob`: shell-style glob (`*`, `?`) over `registry/repo[:tag]`. A pattern
  without a tag matches any tag.
- `digest`: `[registry/repo]@sha256:...`. Matches the digest chalk resolved
  for the image (either the digest written in the Dockerfile or the one chalk
  pinned). The repo part is optional; when present it must match too.

Unknown kinds are reported as evaluation errors and handled per `on_error`,
so configurations written for newer chalk versions fail safe on older ones.

### Registries

`policy.registries` restricts the registries a build pulls images from and
the registries images are pushed to. It works at the level of registry
hosts and repository namespaces, while `golden_images` allowlists exact
images; both can be enabled in the same policy, and an image must then
satisfy both (e.g. `registries` allows only `ghcr.io/acme/*` while
`golden_images` picks the approved base images within it).

```con4m
policy {
  mode: "enforce"
  registries {
    enabled:        true
    pull_allowed:   [("glob", "docker.io/library/*"), ("glob", "cgr.dev"),
                     ("glob", "ghcr.io/acme/*")]
    pull_denied:    [("glob", "ghcr.io/acme/untrusted/*")]
    push_allowed:   [("glob", "ghcr.io/acme/*"), ("glob", "*.dkr.ecr.*.amazonaws.com")]
    push_denied:    [("glob", "docker.io")]
    require_digest: false
    message:        "Use approved registries: https://example.com/registries"
  }
}
```

```json
{
  "id": "registries@1",
  "mode": "enforce",
  "registries": {
    "enabled": true,
    "pull_allowed": [
      ["glob", "docker.io/library/*"],
      ["glob", "cgr.dev"],
      ["glob", "ghcr.io/acme/*"]
    ],
    "pull_denied": [["glob", "ghcr.io/acme/untrusted/*"]],
    "push_allowed": [
      ["glob", "ghcr.io/acme/*"],
      ["glob", "*.dkr.ecr.*.amazonaws.com"]
    ],
    "push_denied": [["glob", "docker.io"]],
    "require_digest": false,
    "message": "Use approved registries: https://example.com/registries"
  }
}
```

| Field                              | Type                                        | Default |
| ---------------------------------- | ------------------------------------------- | ------- |
| `policy.registries.enabled`        | `bool`                                      | `false` |
| `policy.registries.pull_allowed`   | `list[tuple[string, string]]` (kind, value) | `[]`    |
| `policy.registries.pull_denied`    | `list[tuple[string, string]]` (kind, value) | `[]`    |
| `policy.registries.push_allowed`   | `list[tuple[string, string]]` (kind, value) | `[]`    |
| `policy.registries.push_denied`    | `list[tuple[string, string]]` (kind, value) | `[]`    |
| `policy.registries.require_digest` | `bool`                                      | `false` |
| `policy.registries.message`        | `string`                                    | `""`    |

Entries use the kind `glob`; other kinds are evaluation errors (a denylist
entry of an unknown kind could have denied the image, so it is an error
unless a known entry already denied it):

- a value without `/` is a glob over the registry host: `docker.io`,
  `ghcr.io`, `*.dkr.ecr.*.amazonaws.com`, `localhost:*`;
- a value with `/` is a glob over `registry/repository`, e.g.
  `ghcr.io/acme/*` (`*` also matches `/`, so nested repositories match).
  `ghcr.io/acme` alone matches only that repository. As in docker, a first
  component without `.` or `:` that is not `localhost` is a Docker Hub
  namespace (`acme/*` is `docker.io/acme/*`), unless it contains a glob
  character (`*/acme/*` matches `acme` on any registry).

Both sides are normalized like docker references: `alpine` is
`docker.io/library/alpine`, `docker.io/alpine` is
`docker.io/library/alpine`, and `docker.io`, `index.docker.io` and
`registry-1.docker.io` are the same registry (a host glob such as
`docker.*` matches any of the three). Hosts are compared in lower case and the default HTTPS port is dropped, so `GHCR.io:443/acme/app` is
`ghcr.io/acme/app` and `docker.io:443/alpine` is
`docker.io/library/alpine`; other ports are part of the host
(`ghcr.io:8443` is not `ghcr.io`). Tags and digests in entries are
ignored.

Writing entries:

- patterns are globs over the whole name, not prefixes: `ghcr.io/acme`
  matches only the repository `ghcr.io/acme`, not `ghcr.io/acme/app`. Use
  `ghcr.io/acme/*` for a namespace, and a bare host (`ghcr.io`) for a
  whole registry;
- prefer allowlists. A denylist only blocks the spellings it matches;
  references are normalized as above, but the same content can still be
  reached through another name (a mirror, a pull-through cache, a
  different host or IP for the same registry). `pull_denied` and
  `push_denied` are best effort, `pull_allowed` and `push_allowed` fail
  closed.

What is checked:

- pulls: every image in `subjects` (see [What is checked](#what-is-checked):
  `FROM`, `COPY --from`, `RUN --mount=from`, image named contexts) must not
  match `pull_denied` and, when `pull_allowed` is not empty, must match one
  of its entries. An empty allowlist allows every registry that is not
  denied. With `require_digest`, every pulled image must also be referenced
  by digest (`alpine@sha256:...`) as written in the Dockerfile or named
  context; chalk pinning a tag to a digest for its own metadata does not
  count, as it does not pin what the next build pulls;
- other build pulls (`pullRefs`, only checked by this rule since they are
  not part of the built image, so `golden_images` ignores them): the
  BuildKit frontend from `# syntax=<image>` and
  `--build-arg BUILDKIT_SYNTAX=<image>` (both are checked, as either may
  be used; source `syntax`) and registry cache imports
  (`--cache-from <ref>` or `--cache-from type=registry,ref=<ref>`; source
  `cache_from`; `local`, `gha` and other cache types are not registry
  pulls). `require_digest` applies to the frontend but not to cache
  imports, whose tags every `--cache-to` export rewrites. A
  `--cache-from` that cannot be parsed is an error finding;
- pushes: every push target must satisfy `push_denied` and `push_allowed`
  the same way. For `docker build`, the targets are the `--tag`s when the
  build pushes (`--push`, `--output type=registry` or
  `--output type=image,push=true`, as buildx replaces exporter names with
  `--tag`), else the `name`s of the pushing exporters, plus an exporter's
  `dangling-name-prefix` unless BuildKit's `danging-name-empty-only` (sic)
  suppresses it, plus registry cache exports
  (`--cache-to type=registry,ref=<ref>`; `type=inline` cache goes with the
  image). For `docker push`, the pushed reference, or every local tag of
  the repository with `--all-tags`.

On `docker push` the pull checks apply to the images recorded in the
image's chalk mark, as for `golden_images`; the frontend and cache imports
are not recorded and are only checked at build time. Those references
include the base image digests chalk pinned during the build, so
`require_digest` passes on push for any chalked image and is effectively a
build-time check. A policy with pull checks
(`pull_allowed`, `pull_denied` or `require_digest`) needs every pulled
image, so subject collection errors are reported against it and
`on_error` decides: pushing an unchalked image (whose base images are
unknown) under such a policy is an error, and with `on_error: block` in
enforce mode it is blocked. A push-only policy does not need them and
only reports an error when the push targets themselves could not be
determined (e.g. `--all-tags` could not list the tags).

Violations are reported with `image` set to the image or push target and
`source` set to `from`, `copy_from`, `mount_from`, `syntax`, `cache_from`
or `push`.

Not covered:

- `ONBUILD` instructions of a base image run in the build but are not in
  the Dockerfile chalk parses, so images they pull (`ONBUILD COPY --from`)
  are not checked. The base image itself is;
- commands chalk does not wrap: `docker buildx bake`,
  `docker compose build`, `docker compose push` and other tools that push
  (crane, skopeo, `buildctl`) are not checked at all;
- registry mirrors (`registry-mirrors` in the docker daemon, buildkitd
  `mirrors`) and pull-through caches: the reference as written is checked,
  not the mirror that serves it;
- extra tags chalk itself pushes via `docker.docker_registry`, as they are
  operator configuration rather than part of the command;
- insecure or plain HTTP registries: whether docker uses HTTP or skips TLS
  verification depends on daemon (`insecure-registries`, implicitly
  `127.0.0.0/8`) and buildkitd configuration and on DNS resolution, so it is
  not reliably known before the command runs. Deny such registries by host
  instead (e.g. `localhost:*`).

### Custom checks

`custom_check` is called once per checked image with:

1. the image reference (for named image contexts, the context's image reference);
2. the resolved image digest (empty when unknown);
3. the Dockerfile stage alias;
4. the source of the reference, `from`, `copy_from` or `mount_from`.

Return an empty string to pass or a reason to report a violation:

```con4m
func no_latest(image: string, digest: string, stage: string, source: string) {
  if image.ends_with(":latest") {
    return "images must be pinned to a version tag"
  }
  return ""
}

policy.custom_check: func no_latest
```

### Certificates

`policy.certificates` checks the X.509 certificates in the local build
context directories of `chalk docker build` (the context, a cloned git
context and local named contexts), before docker runs:

```con4m
policy {
  mode: "enforce"
  certificates {
    enabled:             true
    expires_within_days: 30
    deny_self_signed:    true
    allowed_key_types:   ["rsa", "ec"]
    allowed_ec_curves:   ["P-256", "P-384"]
    allowed_issuers: [
      ("cn",     "Acme Issuing CA *"),
      ("sha256", "5C:1E:8A:...:C9:B5")
    ]
    exclude_paths: ["test", "**/testdata"]
    message:       "Use certificates from the Acme PKI: https://example.com/pki"
  }
}
```

```json
{
  "id": "certificates@1",
  "mode": "enforce",
  "certificates": {
    "enabled": true,
    "expires_within_days": 30,
    "deny_self_signed": true,
    "allowed_key_types": ["rsa", "ec"],
    "allowed_ec_curves": ["P-256", "P-384"],
    "allowed_issuers": [
      ["cn", "Acme Issuing CA *"],
      ["sha256", "5C:1E:8A:...:C9:B5"]
    ],
    "exclude_paths": ["test", "**/testdata"],
    "message": "Use certificates from the Acme PKI: https://example.com/pki"
  }
}
```

| Field                                      | Type                                        | Default   |
| ------------------------------------------ | ------------------------------------------- | --------- |
| `policy.certificates.enabled`              | `bool`                                      | `false`   |
| `policy.certificates.deny_expired`         | `bool`                                      | `true`    |
| `policy.certificates.deny_not_yet_valid`   | `bool`                                      | `true`    |
| `policy.certificates.expires_within_days`  | `int` (`0` disables)                        | `0`       |
| `policy.certificates.deny_self_signed`     | `bool`                                      | `false`   |
| `policy.certificates.deny_ca`              | `bool`                                      | `false`   |
| `policy.certificates.deny_weak_signatures` | `bool`                                      | `true`    |
| `policy.certificates.min_rsa_key_size`     | `int` (bits, `0` disables)                  | `2048`    |
| `policy.certificates.allowed_key_types`    | `list[string]` (`[]` allows any)            | `[]`      |
| `policy.certificates.allowed_ec_curves`    | `list[string]` (`[]` allows any)            | `[]`      |
| `policy.certificates.allowed_issuers`      | `list[tuple[string, string]]` (kind, value) | `[]`      |
| `policy.certificates.include_paths`        | `list[string]` (`[]` checks every path)     | `[]`      |
| `policy.certificates.exclude_paths`        | `list[string]`                              | `[]`      |
| `policy.certificates.extensions`           | `list[string]` (`[]` is the default set)    | `[]`      |
| `policy.certificates.skip_ca_bundles`      | `bool`                                      | `true`    |
| `policy.certificates.honor_dockerignore`   | `bool`                                      | `true`    |
| `policy.certificates.max_files`            | `int` (> 0)                                 | `100000`  |
| `policy.certificates.max_file_size`        | `int` (bytes, > 0)                          | `1048576` |
| `policy.certificates.message`              | `string`                                    | `""`      |

What is checked, for every certificate (PEM, including bundles and chains,
or DER) found:

- validity: expired (`deny_expired`), not yet valid (`deny_not_yet_valid`)
  or expiring within `expires_within_days`, compared with the time of the
  build;
- `deny_self_signed`: self-issued certificates (subject equals issuer and the
  authority key identifier, when present, equals the subject key
  identifier), root CAs included, unless pinned by a `sha256` entry of
  `allowed_issuers`. Signatures are not verified;
- `deny_ca`: certificates with `CA:TRUE` basic constraints;
- `deny_weak_signatures`: MD2, MD4, MD5, SHA-0 and SHA-1 signatures;
- keys: `min_rsa_key_size`, `allowed_key_types` (`rsa`, `ec`, `ed25519`,
  `ed448`, `dsa`) and `allowed_ec_curves` (`P-256`, `prime256v1` and
  `secp256r1` are equivalent, likewise for P-384 and P-521);
- `allowed_issuers`, when not empty: the issuer must match one entry.
  `cn` and `dn` are globs (`*`, `?`) over the issuer's common name and RFC
  4514 distinguished name (most specific attribute first, e.g.
  `CN=Acme Root CA,O=Acme,C=US`). `sha256` is the fingerprint (hex, colons
  and case ignored) of the issuing certificate, which must itself be in the
  build context (CA bundles skipped by `skip_ca_bundles` count) and must
  have signed the certificate; a self-signed certificate is its own issuer.
  Names are not authenticated, so only `sha256` pins a CA. Kinds are case
  insensitive; an unknown kind is a configuration error.

Checks that cannot be decided are evaluation errors (`on_error` decides),
never silent passes: a file with a malformed or unsupported certificate
block (later certificates of a bundle are still checked), a validity date
that cannot be parsed while a validity check is enabled, or an RSA key
OpenSSL cannot load while `min_rsa_key_size` is set. Keys of unsupported
algorithms or curves are reported by their OID, so `allowed_key_types` and
`allowed_ec_curves` still apply.

A certificate with several problems is one finding whose `reason` lists
them, e.g. `certificate expired on 2020-01-01; weak signature algorithm
sha1WithRSAEncryption`, followed by `message`. `subject` is the path
relative to the build context and the certificate's common name
(`certs/server.pem (api.example.com)`), `location` the path, with `#<n>` for
the n-th certificate of a bundle (`certs/chain.pem#2`). Certificates in
named contexts other than the main one are reported with absolute paths.

Which files are read:

- every regular file of the context with the extensions in `extensions` (by
  default `pem`, `crt`, `cer`, `cert`, `der` and `ca-bundle`; `*` reads
  every file) that contains a PEM certificate or starts like a DER one, not
  only the files the Dockerfile `COPY`s. Test fixtures with expired or
  self-signed certificates therefore need `exclude_paths` or a
  `.dockerignore` entry. FIFOs, sockets and devices are skipped;
- `include_paths` and `exclude_paths` use `.dockerignore` syntax, relative
  to the context; files excluded by `.dockerignore` are skipped
  (`honor_dockerignore`), as they never reach the image. As in BuildKit, a
  `<Dockerfile>.dockerignore` next to the Dockerfile takes precedence over
  the context's `.dockerignore` (main context only). The legacy (non
  BuildKit) builder ignores `<Dockerfile>.dockerignore`, so files it would
  send may go unchecked there;
- symlinks are never followed: docker sends them as links, so a target
  inside the context is checked on its own and one outside never reaches
  the image. `.git` directories are skipped;
- `skip_ca_bundles` skips system and library CA bundles that would otherwise
  flood findings: the directories `etc/ssl/certs/`, `etc/pki/ca-trust/`,
  `etc/pki/tls/certs/`, `usr/share/ca-certificates/` and
  `usr/local/share/ca-certificates/` at any depth, and bundle file names
  (`ca-certificates.crt`, `ca-bundle.crt`, `cacert.pem`,
  `tls-ca-bundle.pem`, `roots.pem`, ...) only under `etc/ssl/`, `etc/pki/`,
  `usr/lib/ssl/`, `usr/local/etc/openssl*/`, `certifi/` and
  `grpc/_cython/_credentials/`, so an application's own `roots.pem` is
  checked. Skipped bundles still supply `sha256` issuer pins;
- work is bounded: a file larger than `max_file_size` is not read and is an
  evaluation error when its extension is one of `extensions` or its first
  64 KiB look like a certificate; at most 1000 certificates are read per
  file (more is an evaluation error); a context with more than `max_files`
  entries stops the scan with an evaluation error.
- not supported (not checked): PKCS#7 (`.p7b`), PKCS#12 (`.p12`, `.pfx`)
  and Java keystores; PEM `TRUSTED CERTIFICATE` blocks are evaluation
  errors.

In the job summary, each offending certificate is listed with its reasons,
and "How to fix" shows `message` (or a generic hint) and the
`allowed_issuers` entries.

`chalk docker push` has no build context, so the rule does not apply to it
and reports nothing: certificates are only checked at build time. A build
whose contexts are not local directories (stdin, URLs, git named contexts)
reports each of them as an evaluation error. Certificates added to an image by `RUN` steps or base
images are not checked, as the image does not exist yet when policies run.
Private keys in the context are not reported by this rule; they belong to
secret scanning.

### Secrets

`policy.secrets` reports secrets (API keys, tokens, credentials) in the
files a `docker build` sends to docker, found with
[trufflehog](https://github.com/trufflesecurity/trufflehog).

```con4m
policy {
  mode: "enforce"
  secrets {
    enabled:          true
    verified_only:    true          # only secrets the provider confirmed as live
    ignore_detectors: ["URI"]
    exclude_paths:    ["tests", "**/fixtures"]
    message:          "Move secrets to the vault: https://example.com/secrets"
  }
}
```

```json
{
  "id": "secrets@1",
  "mode": "enforce",
  "secrets": {
    "enabled": true,
    "verify": true,
    "verified_only": true,
    "detectors": [],
    "ignore_detectors": ["URI"],
    "exclude_paths": ["tests", "**/fixtures"],
    "check_push": false,
    "message": "Move secrets to the vault: https://example.com/secrets"
  }
}
```

| Field                             | Type           | Default |
| --------------------------------- | -------------- | ------- |
| `policy.secrets.enabled`          | `bool`         | `false` |
| `policy.secrets.verify`           | `bool`         | `true`  |
| `policy.secrets.verified_only`    | `bool`         | `true`  |
| `policy.secrets.detectors`        | `list[string]` | `[]`    |
| `policy.secrets.ignore_detectors` | `list[string]` | `[]`    |
| `policy.secrets.exclude_paths`    | `list[string]` | `[]`    |
| `policy.secrets.check_push`       | `bool`         | `false` |
| `policy.secrets.message`          | `string`       | `""`    |

What is checked on `docker build`:

- Every local context directory (the main context, the checkout of a git
  context and local named contexts) is scanned with
  `trufflehog filesystem --json`, before docker runs. The scan uses the
  `tool.trufflehog` settings (local binary, else docker, else the installer;
  `trufflehog_timeout`, 300s by default; `trufflehog_config` for custom
  detectors) whether or not `run_secret_scanner_tools` is enabled, and is
  done once per directory and `exclude_paths` however many policies enable
  the rule. Like on-demand tool scans, it is stopped by the `timeout`
  command after `trufflehog_timeout` plus 60s, or 300s when that is empty;
  without a `timeout` command it is an evaluation error. trufflehog >=
  3.90.9 is required (`--fail-on-scan-errors`); an older one is an
  evaluation error saying so.
- The Dockerfile is always scanned, as BuildKit always sends it and secrets
  in `ENV`/`ARG` defaults end up in the image config: as part of its context
  directory, or on its own when `.dockerignore` excludes it or it is outside
  the context (`-f ../Dockerfile`). Its findings are reported once. A
  Dockerfile read from stdin (`-f -`) is scanned from the content chalk read,
  reported as `Dockerfile (stdin)`.
- The rule does not reuse `SECRET_SCANNER`: chalk's own scan runs on the git
  repository containing the first context, in git mode when it can. Git mode
  reads committed history (secrets that were since removed) but skips
  untracked and ignored files such as a `.env` that docker does send, and
  a failed scan there looks the same as a clean one.
- Files docker does not send are ignored: those matched by
  `<Dockerfile>.dockerignore` (when it exists, main context only) or else the
  context's `.dockerignore` (patterns are cleaned like docker does, e.g.
  `./a` is `a`). `exclude_paths` ignores more paths, relative to the context
  directory, in `.dockerignore` syntax (`*` does not cross `/`, `**` does, a
  directory covers everything under it); negations are rejected. Both are
  passed to trufflehog as anchored `--exclude-paths` regexes (up to 1000;
  directories no negation re-includes are skipped whole), so it does not
  read, unpack or fail on files docker does not send, such as a
  `node_modules` with broken symlinks; results are filtered again
  afterwards.
- A `.git` directory docker sends (not excluded by `.dockerignore`) is not
  scanned except for its `config`, which can hold credentialed remote URLs
  or the `http.extraheader` token `actions/checkout` persists. Objects,
  packs, hooks and logs are not scanned, as reading history is costly.
- `detectors` keeps only the listed trufflehog detectors and
  `ignore_detectors` drops some (names are case-insensitive, e.g. `AWS`,
  `Github`, `URI`).
- Each result is reported with `subject` = detector, `location` =
  `path:line` (relative to the main context, absolute for named contexts)
  and `severity` = `verified`, `unverified` or `unknown`:

  | Result                                                           | `verified_only: true`         | `verified_only: false` |
  | ---------------------------------------------------------------- | ----------------------------- | ---------------------- |
  | verified (provider accepted the secret)                          | violation                     | violation              |
  | unverified (provider rejected it, or the detector cannot verify) | ignored                       | violation              |
  | unknown (verification failed, e.g. no network)                   | evaluation error (`on_error`) | violation              |

  With the defaults (`verify: true`, `verified_only: true`) only secrets
  the provider confirmed as live are violations. A detector that cannot
  verify (no provider API) never yields a violation then, however real the
  secret looks; set `verified_only: false` to report those. A provider that
  rate-limits or is unreachable makes the result `unknown`, an evaluation
  error.

- A `trufflehog:ignore` comment on the line of a secret suppresses it, as
  trufflehog does natively; such lines are not reported.

- Secret values are never stored, logged or reported. Only the detector,
  location, verification status and the detector's rotation guide link are
  kept from trufflehog's output.
- A build context that is not a local directory (stdin, remote tarball), a
  missing trufflehog that cannot be installed, a failed scan or a timeout is
  an evaluation error handled by `on_error`. Secrets trufflehog reported
  before it failed are still reported, so they are violations whatever
  `on_error` says.
- Work is bounded: at most 8 context directories are scanned (more is an
  evaluation error); at most 32 MiB of trufflehog's results and 4 MiB of
  its diagnostics are read (trufflehog is stopped past that, an evaluation
  error that keeps the results read); listing the excluded paths for `-x`
  stops after 100,000 entries, as it runs before `trufflehog_timeout`
  applies (the rest is scanned and filtered afterwards).
- At most 100 findings are reported per policy (violations first); the
  rest are summarized in one more finding.

Verification (`verify`, on by default) means trufflehog sends each candidate
secret to its provider's API from the build host, which is what makes
`verified` findings reliable. For offline builds, or when sending candidates
to providers is not acceptable, set `verify: false`: trufflehog runs with
`--no-verification`, every finding is `unverified`, and `verified_only` must
be `false` (otherwise the policy is a `config` error, as it could never
report anything). Unverified findings include false positives (examples,
test keys), so use them with `audit`, or with `exclude_paths` and
`ignore_detectors`.

On `docker push` the build context is gone, so nothing is checked unless
`check_push` is set. Then the trufflehog results recorded in each pushed
image's chalk mark (`SECRET_SCANNER`, present only when the image was built
with `run_secret_scanner_tools` and a mark template that includes the key)
are reported with the same `detectors`, `ignore_detectors` and
`verified_only` settings. These come from chalk's build-time scan: in git
mode they can include secrets in committed history (the commit is named in
the reason) and are not filtered by `.dockerignore`; `exclude_paths` only
applies to their repository-relative (git mode) paths. Images whose mark
has no `SECRET_SCANNER` pass (e.g. the build did not scan, or only reported
the run-time `@SECRET_SCANNER`), as do unchalked images: the rule cannot tell an image that was never scanned from a clean
one, so use it together with a build policy rather than on its own.

Limitations: secrets passed as build arguments or created during the build
are not scanned; scanning large contexts takes time (bounded by
`trufflehog_timeout`); a scan error anywhere trufflehog walks (outside the
excluded paths) fails the scan, as trufflehog does not attribute every
error to a path. The legacy builder (`DOCKER_BUILDKIT=0`, or docker without
buildx) ignores `<Dockerfile>.dockerignore` and only applies the context's
`.dockerignore`, so with it files the Dockerfile's ignore file excludes are
sent to docker but not scanned.

## Reporting

Findings are published to the `policy` topic, which is subscribed to
`default_out` by default. Subscribe any other sink to forward them, e.g.:

```con4m
sink_config policy_webhook {
  enabled: true
  sink:    "post"
  uri:     "https://example.com/chalk/policy"
}

subscribe("policy", "policy_webhook")
```

The `policy_report` template includes:

| Key                | Type                         | Notes                                                                                                                       |
| ------------------ | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `_POLICY_MODE`     | `string`                     | `enforce` if any evaluated policy is enforced, else `audit`                                                                 |
| `_POLICY_ID`       | `string`                     | `policy.id`, only when a single policy was evaluated and its id is set                                                      |
| `_POLICY_RESULT`   | `string`                     | across policies: `blocked` if any blocked, else `violation` if any, else `error`                                            |
| `_POLICY_RESULTS`  | `list[dict[string, string]]` | per evaluated policy: `id`, `mode`, `on_error`, `result`, `effective_mode`, `mode_source`, `repo`                           |
| `_POLICY_FINDINGS` | `list[dict[string, string]]` | per finding: `policy_id`, `rule`, `kind`, `image`, `digest`, `stage`, `source`, `reason`, `subject`, `location`, `severity` |
| `_POLICY_BUILD`    | `dict[string, any]`          | `command`, `dockerfile_path`, `context`, `tags`, `platforms`                                                                |

`_POLICY_RESULTS` lists every evaluated policy (effective mode `audit` or
`enforce`) in configuration order, including those that passed; policies not
evaluated (mode `off` and not enforced by `enforce_repos`) are omitted. `mode`
is the configured mode, `effective_mode` the mode the policy was evaluated
in, `mode_source` is `enforce_repos` when the repository matched
`enforce_repos` and `default` otherwise, and `repo` is the repository matched
against `enforce_repos` (empty when the policy has none or the repository
could not be determined). `result` is one of `pass`, `violation`, `blocked`
or `error`. A policy's `result` is `blocked` only for enforced policies,
`violation` for a non-blocking violation and `error` when it only produced
non-blocking evaluation errors. Every finding carries the `policy_id` of the
policy that produced it (empty when that policy has no id), so a consumer
storing one row per finding joins it to `_POLICY_RESULTS` by id. The same
image violating two policies yields two findings. For example, with the two
policies above and `FROM busybox`:

```json
{
  "_POLICY_MODE": "enforce",
  "_POLICY_RESULT": "blocked",
  "_POLICY_RESULTS": [
    {
      "id": "golden-images@3",
      "mode": "enforce",
      "on_error": "allow",
      "result": "blocked",
      "effective_mode": "enforce",
      "mode_source": "default",
      "repo": ""
    },
    {
      "id": "chainguard-only@1",
      "mode": "audit",
      "on_error": "block",
      "result": "violation",
      "effective_mode": "audit",
      "mode_source": "default",
      "repo": ""
    }
  ],
  "_POLICY_FINDINGS": [
    {
      "policy_id": "golden-images@3",
      "rule": "golden_images",
      "kind": "violation",
      "image": "busybox",
      "digest": "sha256:...",
      "stage": "",
      "source": "from",
      "reason": "image is not in the list of allowed golden images"
    },
    {
      "policy_id": "chainguard-only@1",
      "rule": "golden_images",
      "kind": "violation",
      "image": "busybox",
      "digest": "sha256:...",
      "stage": "",
      "source": "from",
      "reason": "image is not in the list of allowed golden images"
    }
  ],
  "_POLICY_BUILD": { "command": "build", "tags": ["app:latest"] }
}
```

plus host-level operation and CI keys (`_OPERATION`, `_ACTION_ID`,
`_OP_CHALKER_VERSION`, `_OP_EXIT_CODE`, `_OP_ERRORS`, `BUILD_*`) and
`_COMMIT_ID`, the HEAD commit of the first local git worktree found among the
build's context directories. `_COMMIT_ID` is the commit builds are linked to
pull requests by (matched against a pull request's head or merge commit), so a
policy report from a `push` build on the default branch can be tied to the
merged pull request. Builds on `pull_request` events usually check out a
synthetic merge commit (`refs/pull/N/merge`) that matches neither, the same
limitation build reports have. `_COMMIT_ID` is absent when there is no local
worktree, e.g. for a remote git context
(`docker build https://github.com/org/repo.git#ref`).
Artifact-level keys are not included because a blocked build stops before any
artifact exists; `_POLICY_BUILD` identifies the build instead. Use
`policy.report_template` to select a different template.

The policy report is a report of its own. Like every chalk report it carries a
unique `_ACTION_ID`, which therefore differs from the `_ACTION_ID` of the
`build` or `push` report published by the same command. To correlate the two,
use `BUILD_URI` (the CI run) together with `_POLICY_BUILD` (`tags`,
`dockerfile_path`), which identifies the docker invocation within that run.

The `_POLICY_*` keys can also be added to any other report template. When a
build is blocked, chalk additionally publishes the regular `fail` report with
`_OP_EXIT_CODE = 1`.

Blocking findings and evaluation errors are logged as errors. Audit-mode
violations are logged as warnings (prefixed with
`policy (audit, not enforced):`) so they do not appear in `_OP_ERRORS`. As
`docker_log_level` defaults to `error`, lower it to `warn` to see audit
findings on the console.

### GitHub Actions job summary

When `GITHUB_STEP_SUMMARY` is set (GitHub Actions), every `chalk docker build`
or `chalk docker push` that evaluates policies appends a short Markdown section
to the [job summary](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary),
including when all policies pass and when the command is blocked:

- an alert stating the outcome: `CAUTION` when blocked, `WARNING` for audit
  violations that `enforce` would block, `NOTE` when policies could only report
  evaluation errors, `TIP` when all passed;
- the command and its first image tag;
- when there are findings, a table of the offending images (digest shortened),
  how each is used (`FROM`, `COPY --from`, `RUN --mount from` and the stage) and
  why (the policy's `message`, else the finding's reason), and a "How to fix"
  line with the `message` and up to 10 allowed patterns;
- a collapsed "Policy details" block with each evaluated policy's mode, why it
  has that mode (`enforce_repos` match, default, or unknown repository), result
  and finding count, the chalk version, the repository used for
  `enforce_repos`, and the location of the uploaded policy report when the
  `policy` topic goes to a `presign` sink (without the presigned query string).

Sections are appended, never truncated, so several chalk invocations in one
step each add theirs. Rows are capped (50 findings, 50 policies) to stay well
under GitHub's 1 MiB per-step limit. The summary is written by the chalk
process wrapping docker, and failing to write it (unset or unwritable path,
size limit) is only a warning: it never changes the command's outcome. Set
`policy.github_step_summary = false` to turn it off; it is a con4m-only
setting, not part of `policy.config_json`.

## Distributing policies

Policies are regular chalk configuration, so they can be distributed like any
other configuration: embedded with `chalk load`, provided as an external
config file, or published as a reusable component whose values are set via
component parameters. A component can take the whole policy as a JSON string
parameter and assign it to `policy.config_json`, so the system that generates
policies and the one that distributes the component do not need to know each
other's formats.

Policy configuration is read once per evaluation, and each policy's rules
are loaded and checked before the next policy's. Subject collection,
metadata decoding and rule evaluation use the same `on_error` setting;
errors in these steps cannot silently bypass `on_error = "block"`.
Subject collection errors (for example pushing an unchalked image) are
reported against rules that need every referenced image, such as
`golden_images`; `custom_check` only sees the images that could be determined.

## Adding rules

Each rule is a standalone module under `src/policy/rules/` that registers
itself with `newPolicyRule` (see `src/policy/api.nim`) and is listed in
`src/policy/rules.nim`. A rule reads its own configuration in `load`, returns
findings from `check`, and sets `requiresAllSubjects` when an incomplete list
of images could let a disallowed one through.

Rules that need more than the referenced images register with
`newPolicyInputRule` and receive the whole `PolicyInput`:

- `command`: `build` or `push`;
- `contextDirs`: local build context directories (the checked out subdirectory
  for git contexts, plus local named contexts), empty for `push`;
- `mainContextDir`: the entry of `contextDirs` that is the main build context,
  e.g. to apply `<Dockerfile>.dockerignore` only there; empty when the main
  context is not a local directory, in which case `contextDirs` only has
  named contexts;
- `contextErrors`: build contexts that are not local directories (stdin,
  tarball URLs, git named contexts). Image and stage named contexts
  (`docker-image://`, `oci-layout://`, `target:`) are left to image rules. The
  engine reports these against rules registered with `requiresContext`, so a
  context-scanning rule cannot pass a context it never saw;
- `dockerfilePath`: the Dockerfile of a build, so rules can honor
  `<Dockerfile>.dockerignore`; empty for `push` and for `-f -`;
- `stdinDockerfile`: the content of a Dockerfile read from stdin (`-f -`),
  which has no path but is sent to the builder like any other;
- `pushTargets`: the image references the command pushes (`build --push` tags,
  exporter names and `--cache-to type=registry` refs, or the `docker push`
  reference and, with `--all-tags`, every local tag);
- `pullRefs`: `build` only, images the build pulls that are not part of the
  built image (BuildKit frontend from `# syntax=`/`BUILDKIT_SYNTAX`, registry
  `--cache-from` refs), kept out of `subjects` so image rules such as
  `golden_images` do not check them; `pullRefErrors` holds those that could
  not be parsed, which rules checking `pullRefs` must report;
- `pushMarks`: chalk marks of the images `push` pushes, for those that are
  chalked;
- `host`: `build` only, a copy of the chalk-time host info collected before
  policies run, such as `SBOM`, `SAST` and `SECRET_SCANNER` when those tools
  are enabled. `push` policies run before collection, so `host` is nil there
  and push rules read `pushMarks`.

Findings about something other than an image (`newSubjectFinding`) set
`subject` (e.g. a package purl, a file or a registry) and optionally
`location` (e.g. `path:line`) and `severity` (as reported by the scanner),
and leave `image` empty. The job summary shows `subject` where it would show
the image.

Rules that read external tool output (`tool.*`, e.g. syft or semgrep) share
`src/policy/tools.nim` rather than running the tools themselves:

- on build, `contextToolOutputs` gives, per context directory (at most
  `maxContextDirs`), chalk's own output (`run_*_tools`) when the directory is
  below the one chalk scanned (`EXTERNAL_TOOL_DURATION` records it), else
  the output of running the enabled tools of that kind on the directory on
  demand, once per process. Chalk scans the git repository containing the
  first context, so rules keep only what is inside each context directory
  (`contextPath`). Missing output is an evaluation error, so `on_error`
  decides, and so is a tool that failed when every enabled tool was to run,
  even if another produced output (not one that a `firstOnly` request or a
  `stop_on_success` tool's output stands in for). Output larger than
  `maxToolOutputBytes` (128 MiB of JSON) is an error rather than parsed.
  Such rules must register with `requiresContext = true`: context
  directories are only collected for them, and contexts that are not local
  directories are reported against them by the engine (so
  `contextToolOutputs` does not repeat them);
- on push, `pushedToolOutputs` reads the output recorded in the pushed
  images' chalk marks;
- `capFindings` bounds the findings a rule reports.

On-demand runs ignore `run_sbom_tools`, `run_sast_tools` and
`run_secret_scanner_tools`: enabling a rule that needs a tool's output runs
the tool. Like chalk's own runs they may install it first (e.g. download the
syft installer, or run the `anchore/syft` docker image); installers are
bounded by the tool's timeout. Whatever the tool's callbacks do, each scan
is stopped by the `timeout` command after the tool's own timeout
(`syft_timeout`, `semgrep_timeout`, `trufflehog_timeout`, 300s by default)
plus 60s, or after `policyToolTimeout` (300s) when that is empty or 0;
without a `timeout` command the scan is an evaluation error. A build may
therefore take up to `maxContextDirs` (8) contexts x enabled tools x
timeout longer. These runs do not count as chalk's own: when chalk's run
failed, it still runs the tool again for the chalk mark.

On push the tool output comes only from the pushed images' chalk marks, as
the build context is gone and the tools cannot run on it. Images whose mark
does not record the output pass: the default mark templates do not include
`SBOM`, `SAST` or `SECRET_SCANNER`, unchalked images have no mark, and a
mark may keep the key in an object store (`@SBOM`, logged at trace level).
Checking pushes requires mark templates that record the key. The recorded
output covers everything chalk scanned when it built the image (the git
repository of the first build context), not just the build context, as push
cannot tell which part was the context.

`src/policy/sbom.nim` builds on it for rules that read SBOMs (CycloneDX, SPDX
or syft JSON): `policySboms` returns the packages of each build context, or
of each pushed image. On build it keeps the packages found within each
context directory, dropping those whose every location the context's
`.dockerignore` leaves out of the build (the Dockerfile's
`<Dockerfile>.dockerignore` for the main context).

Shared helpers for rules:

- `src/policy/dockerignore.nim`: `loadDockerignore(dir, dockerfilePath)`
  reads the ignore file docker applies to a context
  (`mainContextDockerfile(input, dir)` gives the Dockerfile path for the main
  context only), `isIgnored(relPath)` and `prunes(relDir)` match paths with
  the moby-compatible matcher of `src/docker/tar.nim`;
- `src/policy/purl.nim`: `purlParts`, `purlType`, `parsePurlPattern` and
  `matches`/`firstMatch` for purl patterns with globs and version ranges
  (e.g. `pkg:npm/lodash@<4.17.21`, `pkg:npm/@angular/*`), ignoring case,
  qualifiers and subpaths, decoding percent-encoding and normalizing pypi
  names and go `v` versions.

A rule with settings in `policy.config_json` registers its section at module
initialization with `registerPolicyJsonSection(name, validate)`, as
configurations can be read before rules are loaded. `validate` receives the
section's JSON object and raises `ValueError` for anything it does not accept,
usually via `validateFields` and `validatePairs`. Settings are then read with
the `policy*Setting` accessors, which read the same path from con4m when
`policy.config_json` is not set.

## Limitations

- Policies are a guardrail, not a security boundary: running the real `docker`
  binary directly bypasses chalk.
- Configuration embedded with `chalk load` is only updated by loading it
  again.
- `docker buildx bake` and `docker compose build` are not wrapped by chalk
  and are therefore not covered.
- Older chalk marks may omit images supplied through named contexts. When
  such metadata is incomplete, push policies report an evaluation error;
  `on_error` determines whether to allow the push. Rebuilding with this
  version of chalk records the image context references for subsequent push
  checks, whether or not policies are enabled.
- Marks recorded before `RUN --mount=from` images were added to
  `DOCKER_COPY_IMAGES` (with `mount` set) do not list them, so push cannot
  check mounted images of such marks.
- Policies that need the contents of the built image (for example its SBOM)
  are not supported yet, as they require evaluating the image after it is
  built but before it is pushed.
- A remote git build context is checked out for rules that scan the build
  context, and docker then builds that checkout, so it builds the commit the
  rules inspected. The checkout has no git submodules and no `.git`
  directory, which BuildKit's git source provides, so when the repository has
  a `.gitmodules` file or the build arg `BUILDKIT_CONTEXT_KEEP_GIT_DIR` is
  set, docker fetches the git context itself instead. This is reported as an
  evaluation error of those rules, as the submodules or `.git` are not
  checked, and a branch or tag that moves between the policy check and the
  build is built at its new commit.

Secrets policy scans enable TruffleHog `--fail-on-scan-errors` and also inspect
stderr for filesystem traversal/chunk failures that the scanner logs without
failing its exit status. Such scans produce an evaluation error governed by
`on_error`, keeping the results trufflehog printed, and are cached like
completed scans so several policies do not wait for a timeout again.
Diagnostic values are never
included in findings or logs. Verification failures retain their existing
`verified_only` behavior, and native `trufflehog:ignore` suppressions remain
respected. Exclusions are anchored at the scanned directory, so ordinary
directories such as `app.git` (or a context below one) remain scanned.

SBOM policy parsing retains every package occurrence. A repository scan keeps a
package in a build context when any recorded location belongs to that context;
findings use an in-context location. Packages without locations remain eligible.
SPDX dependencies do not need optional version or purl metadata. The row
the document describes (`documentDescribes`, `DESCRIBES` or `DESCRIBED_BY`) is
the scanned source and excluded, whatever its version or purl, when its
`primaryPackagePurpose` is `FILE`, `CONTAINER` or `DIRECTORY`, or it is
syft's `SPDXRef-DocumentRoot-*` (syft gives a scanned image its digest as
version). Described applications and libraries remain checked. syft JSON
licenses may be objects or, in older schemas, plain strings; empty values are
skipped. Optional omitted package arrays and empty arrays
are valid; present arrays must contain package objects with nonempty names.
Malformed arrays/entries and content omitted by package-count or nesting limits
produce evaluation errors governed by `on_error`.
