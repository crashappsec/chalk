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
`config` evaluation error and no rule runs. This never blocks the build,
whatever `mode` or `on_error` the document asks for, since a document that
cannot be read cannot be trusted either. Only policy settings can be expressed,
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
  string one) and never blocks. The other entries are still evaluated. An entry
  with a duplicate `id` invalidates every entry using that `id`.
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
  the policy invalid: it is reported as a `config` evaluation error and never
  blocks, like any other invalid policy.

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
    "allowed_issuers": [["cn", "Acme Issuing CA *"], ["sha256", "5C:1E:8A:...:C9:B5"]],
    "exclude_paths": ["test", "**/testdata"],
    "message": "Use certificates from the Acme PKI: https://example.com/pki"
  }
}
```

| Field                                     | Type                                        | Default   |
| ----------------------------------------- | ------------------------------------------- | --------- |
| `policy.certificates.enabled`             | `bool`                                      | `false`   |
| `policy.certificates.deny_expired`        | `bool`                                      | `true`    |
| `policy.certificates.deny_not_yet_valid`  | `bool`                                      | `true`    |
| `policy.certificates.expires_within_days` | `int` (`0` disables)                        | `0`       |
| `policy.certificates.deny_self_signed`    | `bool`                                      | `false`   |
| `policy.certificates.deny_ca`             | `bool`                                      | `false`   |
| `policy.certificates.deny_weak_signatures`| `bool`                                      | `true`    |
| `policy.certificates.min_rsa_key_size`    | `int` (bits, `0` disables)                  | `2048`    |
| `policy.certificates.allowed_key_types`   | `list[string]` (`[]` allows any)            | `[]`      |
| `policy.certificates.allowed_ec_curves`   | `list[string]` (`[]` allows any)            | `[]`      |
| `policy.certificates.allowed_issuers`     | `list[tuple[string, string]]` (kind, value) | `[]`      |
| `policy.certificates.include_paths`       | `list[string]` (`[]` checks every path)     | `[]`      |
| `policy.certificates.exclude_paths`       | `list[string]`                              | `[]`      |
| `policy.certificates.extensions`          | `list[string]` (`[]` is the default set)    | `[]`      |
| `policy.certificates.skip_ca_bundles`     | `bool`                                      | `true`    |
| `policy.certificates.honor_dockerignore`  | `bool`                                      | `true`    |
| `policy.certificates.max_files`           | `int` (> 0)                                 | `100000`  |
| `policy.certificates.max_file_size`       | `int` (bytes, > 0)                          | `1048576` |
| `policy.certificates.message`             | `string`                                    | `""`      |

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
  build context; a self-signed certificate is its own issuer. Names are not
  authenticated, so only `sha256` pins a CA. Unknown kinds are evaluation
  errors unless another entry matches.

A certificate with several problems is one finding whose `reason` lists
them, e.g. `certificate expired on 2020-01-01; weak signature algorithm
sha1WithRSAEncryption`, followed by `message`. `subject` is the path
relative to the build context and the certificate's common name
(`certs/server.pem (api.example.com)`), `location` the path, with `#<n>` for
the n-th certificate of a bundle (`certs/chain.pem#2`). Certificates in
named contexts other than the main one are reported with absolute paths.

Which files are read:

- files with the extensions in `extensions` (by default `pem`, `crt`, `cer`,
  `cert`, `der` and `ca-bundle`; `*` reads every file) that contain a PEM
  certificate or start like a DER one;
- `include_paths` and `exclude_paths` use `.dockerignore` syntax, relative
  to the context; files excluded by `.dockerignore` are skipped
  (`honor_dockerignore`), as they never reach the image. As in BuildKit, a
  `<Dockerfile>.dockerignore` next to the Dockerfile takes precedence over
  the context's `.dockerignore` (main context only);
- symlinks are never followed: docker sends them as links, so a target
  inside the context is checked on its own and one outside never reaches
  the image. `.git` directories are skipped;
- `skip_ca_bundles` skips system and library CA bundles that would otherwise
  flood findings (`ca-certificates.crt`, `ca-bundle.crt`, `cacert.pem`,
  `tls-ca-bundle.pem`, `roots.pem`, ... and `etc/ssl/certs/`,
  `etc/pki/ca-trust/`, `usr/share/ca-certificates/`);
- work is bounded: files larger than `max_file_size` are skipped, at most
  1000 certificates are read per file, and a context with more than
  `max_files` entries stops the scan with an evaluation error (`on_error`
  decides).

In the job summary, each offending certificate is listed with its reasons,
and "How to fix" shows `message` (or a generic hint) and the
`allowed_issuers` entries.

`chalk docker push` has no build context, so the rule does not apply to it
and reports nothing. Certificates added to an image by `RUN` steps or base
images are not checked, as the image does not exist yet when policies run.
Private keys in the context are not reported by this rule; they belong to
secret scanning.

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
`_OP_CHALKER_VERSION`, `_OP_EXIT_CODE`, `_OP_ERRORS`, `BUILD_*`).
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
- `contextDirs`: local build context directories (the cloned checkout for git
  contexts, plus local named contexts), empty for `push`;
- `pushTargets`: the image references the command pushes (`build --push` tags,
  or the `docker push` reference and, with `--all-tags`, every local tag);
- `host`: chalk-time host info collected before policies run, such as `SBOM`,
  `SAST` and `SECRET_SCANNER` when those tools are enabled.

Findings about something other than an image (`newSubjectFinding`) set
`subject` (e.g. a package purl, a file or a registry) and optionally
`location` (e.g. `path:line`) and `severity` (as reported by the scanner),
and leave `image` empty. The job summary shows `subject` where it would show
the image.

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
