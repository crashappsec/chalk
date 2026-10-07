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

Policies only take effect once `policy.mode` is set to `audit` or `enforce`.

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
  external base), and every image referenced by `COPY --from=<image>` in those
  stages. As in BuildKit, a stage is used when the target reaches it through
  `FROM`, `COPY --from` or `RUN --mount=from`; other stages are never pulled
  and are not checked. A `RUN --mount` chalk cannot evaluate makes every stage
  count as used. Without buildx (legacy builder) every stage is checked. Named contexts with
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
- `chalk docker push`: the base and `COPY --from` images recorded in the
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
| `policy.config_json`                   | `string` (JSON object)                            | `""`              |
| `policy.on_error`                      | `string`, one of `allow`, `block`                 | `"allow"`         |
| `policy.report_template`               | `string`                                          | `"policy_report"` |
| `policy.custom_check`                  | `func (string, string, string, string) -> string` | unset             |
| `policy.golden_images.enabled`         | `bool`                                            | `false`           |
| `policy.golden_images.check_copy_from` | `bool`                                            | `true`            |
| `policy.golden_images.allowed`         | `list[tuple[string, string]]` (kind, value)       | `[]`              |
| `policy.golden_images.message`         | `string`                                          | `""`              |

With `golden_images.enabled` and an empty `allowed` list, every external
image is a violation.

`policy.id` identifies the policy (e.g. `name@version`) and is reported as
`_POLICY_ID`.

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
4. the source of the reference, `from` or `copy_from`.

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

| Key                | Type                         | Notes                                                                       |
| ------------------ | ---------------------------- | --------------------------------------------------------------------------- |
| `_POLICY_MODE`     | `string`                     | `audit` or `enforce`                                                        |
| `_POLICY_ID`       | `string`                     | `policy.id`, when set                                                       |
| `_POLICY_RESULT`   | `string`                     | `violation` (audit), `blocked` (enforce), `error`                           |
| `_POLICY_FINDINGS` | `list[dict[string, string]]` | per finding: `rule`, `kind`, `image`, `digest`, `stage`, `source`, `reason` |
| `_POLICY_BUILD`    | `dict[string, any]`          | `command`, `dockerfile_path`, `context`, `tags`, `platforms`                |

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

## Distributing policies

Policies are regular chalk configuration, so they can be distributed like any
other configuration: embedded with `chalk load`, provided as an external
config file, or published as a reusable component whose values are set via
component parameters. A component can take the whole policy as a JSON string
parameter and assign it to `policy.config_json`, so the system that generates
policies and the one that distributes the component do not need to know each
other's formats.

Policy configuration is read once per evaluation. Subject collection,
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
- Images mounted with `RUN --mount=from=<image>` are not checked; the flag is
  only used to find the stages a build uses.
- Policies that need the contents of the built image (for example its SBOM)
  are not supported yet, as they require evaluating the image after it is
  built but before it is pushed.
