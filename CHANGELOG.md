# Chalk Release Notes

## On the `main` branch

### Breaking Changes

- Symlink behavior can now be different between chalking/non-chalking
  operations. As such:

  - renamed `symlink_behavior` -> `symlink_behavior_chalking` config
  - renamed `--symlink-behavior` -> `--chalk-symlink-behavior` CLI flags
  - added `symlink_behavior_non_chalking` config
  - added `--scan-symlink-behavior` CLI flag along with `--ignore` choice flag

  ([#515](https://github.com/crashappsec/chalk/pull/515))

- Configuration `ignore_patterns` was used only in chalking operations.
  Now it is used in all chalk operations.
  ([#515](https://github.com/crashappsec/chalk/pull/515))

### New Features

- X509 Certificate codec which can parse PEM files and report
  metadata keys about the certificate:

  - `_X509_VERSION`
  - `_X509_SUBJECT`
  - `_X509_SUBJECT_ALTERNATIVE_NAME`
  - `_X509_SERIAL`
  - `_X509_KEY`
  - `_X509_KEY_USAGE`
  - `_X509_EXTENDED_KEY_USAGE`
  - `_X509_BASIC_CONSTRAINTS`
  - `_X509_ISSUER`
  - `_X509_SUBJECT_KEY_IDENTIFIER`
  - `_X509_AUTHORITY_KEY_IDENTIFIER`
  - `_X509_NOT_BEFORE`
  - `_X509_NOT_AFTER`
  - `_X509_EXTRA_EXTENSIONS`

  ([#515](https://github.com/crashappsec/chalk/pull/515))

- `_OP_ARTIFACT_PATH_WITHIN_VCTL` key which indicates path of the file
  in the git repo.
  ([#515](https://github.com/crashappsec/chalk/pull/515))
- Scanning of environment variables for artifacts.
  Currently only `certs` codec supports scanning env vars.
  This behavior can be customized (by default on) via new`env_vars`
  configuration or`--[no-]env-vars` flag.
  Additionally new `_OP_ARTIFACT_ENV_VAR_NAME` key indicates name of the
  environment variable where the artifact was found.
  ([#515](https://github.com/crashappsec/chalk/pull/515))

### Fixes

- Docker pass-through commands (non build/push) commands were capturing all
  IO which could possibly fail with OOM. Standard in/out is no longer captured
  for pass-through commands to resolve that.
  ([#514](https://github.com/crashappsec/chalk/pull/514))

## 0.5.7

**May 22, 2025**

### Fixes

- `docker push` of chalked image in CI will report different `METADATA_ID`
  than what is in the chalkmark.
  This was a regression in 0.5.5 which was fixing another bug.
  ([#516](https://github.com/crashappsec/chalk/pull/516))

## 0.5.6

**Apr 30, 2025**

### New Features

- `VCS_MISSING_FILES` key. It lists all files tracked by version control
  however missing on disk while chalking an artifact.
  ([#509](https://github.com/crashappsec/chalk/pull/509))

## 0.5.5

**Apr 15, 2025**

### Breaking Changes

- Tech stack plugin is removed and all its associated
  configurations as well as keys.
  ([#352](https://github.com/crashappsec/chalk/pull/352))
- `_SIGNATURES` now includes full cosign attestation payload
  instead of just the signature. This allows to externally
  validate the signature without relying on access to the registry.
  ([#505](https://github.com/crashappsec/chalk/pull/505))

### Fixes

- In interactive shell, autocomplete script is now only updated
  when its content is changed.
  ([#493](https://github.com/crashappsec/chalk/pull/493))
- Docker registry throttling errors are retried now
  before failing out from wrapped build.
  ([#502](https://github.com/crashappsec/chalk/pull/502))

### New Features

- Basic support for AWS CodeBuild pipelines.
  ([#494](https://github.com/crashappsec/chalk/pull/494))
- `BUILD_ORIGIN_URI` key which reports URI of resource which originated
  the CI build. In most cases it will be the repository but could be
  other resources such as S3 object URI for AWS Code Builds.
  ([#494](https://github.com/crashappsec/chalk/pull/494))
- Object store which allows to upload specific keys to an object
  store and reference them in the report vs including full value
  in the raw report. This allows to both deduplicate
  some common metadata between builds (e.g. SBOM) as well as make
  report smaller.
  See `object_store_config` how to configure the object store.
  TLDR:

  ```
  auth_config example {
    auth: "jwt"
    token: env("TOKEN")
  }

  object_store_config example {
    object_store: "presign"
    object_store_presign {
      uri: "https://example.com/objects"
      read_auth: "example"
      write_auth: "example"
    }
  }

  report_template example {
    key.EXAMPLE.use: true
    key.EXAMPLE.object_store: "example"
    default_object_store {
      enabled: true
      object_store: "example"
    }
  }
  ```

  ([#500](https://github.com/crashappsec/chalk/pull/500))

- `copy_report_template_keys` built-in function which copies all keys
  as they are subscribed from one report template to another:

  ```
  report_template one {
    key.ONE.use = true
    key.TWO.use = false
  }
  copy_report_template_keys("one", "two")
  ```

  ([#500](https://github.com/crashappsec/chalk/pull/500))

- `network.tcp_socket_statuses` configuration which allows to filter
  TCP sockets with specific statuses to be reported in `_OP_TCP_SOCKET_INFO`.
  ([#504](https://github.com/crashappsec/chalk/pull/504))

## 0.5.4

**Feb 19, 2025**

### Fixes

- `chalk insert` was running external tools on the exact path
  being chalked. For example `chalk insert hello.py` would run `semgrep`
  on `hello.py`. Now chalk will compute nearest `git` repository
  and run external tools on it instead.
  ([#485](https://github.com/crashappsec/chalk/pull/485))
- When `Dockerfile` specifies syntax directive, chalk checks buildkit
  frontend version compatibility as older frontends do not support
  `--build-context` CLI argument. Passing the flag would fail the
  wrapped build and chalk would fallback to vanilla docker build.
  More about syntax directive
  [here](https://docs.docker.com/reference/dockerfile/#syntax).
  ([#486](https://github.com/crashappsec/chalk/pull/486))
- Heartbeat reports had older timestamps. Reporting state was cleared
  before sleeping for the heartbeat which meant that timestamp was
  always off by the heartbeats interval - default 10 minutes.
  ([#487](https://github.com/crashappsec/chalk/pull/487))

### New Features

- `EXTERNAL_TOOL_DURATION` key which reports external tool duration
  for each invocation.
  ([#488](https://github.com/crashappsec/chalk/pull/488))
- `run_secret_scanner_tools` configuration which then collects new
  `SECRET_SCANNER` key. Currently only trufflehog is supported.
  ([#489](https://github.com/crashappsec/chalk/pull/489))

## 0.5.3

**Feb 3, 2025**

### Fixes

- Incorrect base image for `DOCKER_COPY_IMAGES` when using stage index
  (e.g. `COPY --from=<index>`).
  ([#479](https://github.com/crashappsec/chalk/pull/479))
- Installing shell autocompletion script was wiping bash/zsh rc files.
  ([#480](https://github.com/crashappsec/chalk/pull/480))

## 0.5.2

**Jan 28, 2025**

### Fixes

- `_REPO_TAGS` did not include all pushed tags when using `buildx build --push`
  without `--load`.
  ([#471](https://github.com/crashappsec/chalk/pull/471))
- Requests to AWS API were incorrectly signed due to additional headers
  being included in AWS sigv4. This impacted:

  - uploading reports to s3 sink
  - lambda plugin as it could not get caller identity

  This was a regression from `0.4.14`.

  ([nimutils #82](https://github.com/crashappsec/nimutils/pull/82),
  [#473](https://github.com/crashappsec/chalk/pull/473))

## 0.5.1

**Jan 17, 2025**

### Fixes

- For `docker build`, `--platform` was not honored when pinning base images.
  ([#468](https://github.com/crashappsec/chalk/pull/468))
- `_REPO_URLS` was not extracting `org.opencontainers.image.url` annotation
  correctly.
  ([#468](https://github.com/crashappsec/chalk/pull/468))

## 0.5.0

**Jan 08, 2025**

### Breaking Changes

- Changes to docker image related fields.

  Removed keys:

  - `_IMAGE_DIGEST` - there are cases when the image digest is mutated.
    For example `docker pull && docker push` drops all
    manifest annotations resulting in a change to the digest.
    It is recommended to use `_REPO_DIGESTS` instead as it will
    include all digests per repository.
  - `_IMAGE_LIST_DIGEST` - it is possible to create manifests outside the build
    context which results in multiple list manifests for the same image. The new
    `_REPO_LIST_DIGESTS` key provides a list of all digests per repository.

  Changed keys:

  - `_REPO_DIGESTS` previously (and incorrectly) would return the first registry
    and the image digest. This key now provides a list of image digests by
    registry and image name.

    **Before**:

    ```json
    {
      // old format
      "_REPO_DIGESTS": {
        "224111541501.dkr.ecr.us-east-1.amazonaws.com/co/chalketl/scripts": "249ce02d7f5fe0398fc87c2fb6c225ef78912f038f4be4fe9c35686082fe3cb0"
      }
    }
    ```

    **Now**:

    ```json
    {
      // new format
      "_REPO_DIGESTS": {
        "registry-1.docker.io": {
          "library/alpine": [
            "029a752048e32e843bd6defe3841186fb8d19a28dae8ec287f433bb9d6d1ad85"
          ]
        }
      }
    }
    ```

  - `_REPO_TAGS` now includes tags which are only available in the registry.
    Builds without `--push`, even when provided with `--tag`, will not populate
    `_REPO_TAGS` anymore. In addition similarly to `_REPO_DIGESTS`, it is
    an object where each tag is associated with its digest (either list or image
    digest). For example:

    ```json
    {
      "_REPO_TAGS": {
        "registry-1.docker.io": {
          "library/alpine": {
            "latest": "1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a"
          }
        }
      }
    }
    ```

  - `DOCKER_BASE_IMAGES` - sub-keys:

    - `name` renamed to `uri`; contains the full repository uri (tag and digest)
    - new `registry` key; the normalized registry uri (domain and optional port)
    - new `name` key; the normalized repo name within the registry

    **Before**:

    ```json
    // old format
    {
      "from": "nginx:1.27.0",
      "tag": "1.27.0",
      "name": "nginx:1.27.0",
      "repo": "nginx"
    }
    ```

    **Now**:

    ```json
    // new format
    {
      "from": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
      "uri": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
      "repo": "nginx",
      "registry": "registry-1.docker.io",
      "name": "library/nginx",
      "tag": "1.27.0",
      "digest": "97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe"
    }
    ```

  - `DOCKER_COPY_IMAGES` - similar to `DOCKER_BASE_IMAGES`, the `name` key has
    been renamed to `uri` and adds the `registry` and `name` keys.

  New keys:

  - `_REPO_LIST_DIGESTS` - similar to `_REPO_DIGESTS` but enumerates any known
    list digests. Example:

    ```json
    {
      "_REPO_LIST_DIGESTS": {
        "registry-1.docker.io": {
          "library/alpine": [
            "1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a"
          ]
        }
      }
    }
    ```

  - `_REPO_URLS` - similar to `_REPO_DIGESTS` but shows human-accessible URL,
    if known as per OCI image annotation or computed for Docker Hub images.
    Example:

    ```json
    {
      "_REPO_URLS": {
        "registry-1.docker.io": {
          "library/alpine": "https://hub.docker.com/_/alpine"
        }
      }
    }
    ```

  **NOTE:** All `_REPO_*` keys normalize registry to its canonical domain. For
  example, docker hub is normalized to `registry-1.docker.io`. Additionally, all
  image names are normalized to how they are stored in the registry. Note
  `library/` prefix for `alpine` in the example above.

  ([#450](https://github.com/crashappsec/chalk/pull/450),
  [#453](https://github.com/crashappsec/chalk/pull/453),
  [#464](https://github.com/crashappsec/chalk/pull/464))

- Git time-related fields are now reported in ISO-8601 format whereas
  previously it was reporting using default git format.

  **Before**:

  ```json
  {
    "DATE_AUTHORED": "Tue Dec 10 11:46:06 2024 -0500",
    "DATE_COMMITTED": "Tue Dec 10 11:46:06 2024 -0500",
    "DATE_TAGGED": "Tue Dec 10 11:46:06 2024 -0500"
  }
  ```

  **Now**:

  ```json
  {
    "DATE_AUTHORED": "2024-12-10T16:46:06.000Z",
    "DATE_COMMITTED": "2024-12-10T18:49:00.000Z",
    "DATE_TAGGED": "2024-12-10T18:49:00.000Z"
  }
  ```

  This also affects all host-level keys in addition to chalk-level keys:

  - `DATE_AUTHORED`
  - `DATE_COMMITTED`
  - `DATE_TAGGED`
  - `_DATE_AUTHORED`
  - `_DATE_COMMITTED`
  - `_DATE_TAGGED`

  To make parsing easier, in addition to human readable `DATE_*` fields,
  new `TIMESTAMP_*` fields are added which report milliseconds since
  Unix epoch:

  ```json
  {
    "DATE_AUTHORED": "2024-12-10T16:46:06.000Z",
    "DATE_COMMITTED": "2024-12-10T18:49:00.000Z",
    "DATE_TAGGED": "2024-12-10T18:49:00.000Z",
    "TIMESTAMP_AUTHORED": 1733849166000,
    "TIMESTAMP_COMMITTED": 1733856540000
    "TIMESTAMP_TAGGED": 1733856540000
  }
  ```

  ([#458](https://github.com/crashappsec/chalk/pull/458))

- All datetime fields are now reported in UTC TZ whereas previously were
  reported in machines local TZ
  ([#458](https://github.com/crashappsec/chalk/pull/458))

### Fixes

- `DOCKERFILE_PATH_WITHIN_VCTL` key is no longer reported when providing
  Dockerfile contents via `stdin`
  ([#454](https://github.com/crashappsec/chalk/pull/454)).

- Git time-related fields report accurate timezone now. Previously
  wrong commit TZ was being reported as committed in git which was not correct.
  ([#458](https://github.com/crashappsec/chalk/pull/458))

- `_OP_ERRORS` includes all logs from chalkmark `ERR_INFO`,
  even when its collection fails
  ([#459](https://github.com/crashappsec/chalk/pull/459))

- `docker buildx build` without both `--push` or `--load` report their
  chalkmarks now. Chalkmarks however are missing any runtime keys
  as those cannot be inspected due to image neither being pushed
  to a registry or loaded into local daemon. Such an image is normally
  inaccessible however it is still in buildx cache hence it can be
  used in subsequent builds.
  ([#459](https://github.com/crashappsec/chalk/pull/459))

### New Features

- Chalk pins base images in `Dockerfile`. For example:

  ```Dockerfile
  FROM alpine
  ```

  Will be pinned to:

  ```Dockerfile
  FROM alpine@sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
  ```

  This makes docker build deterministic and avoids any possible
  race conditions between chalk looking up metadata about
  base image and actual docker build.
  ([#449](https://github.com/crashappsec/chalk/pull/449))

- Docker annotations new keys:

  - `DOCKER_ANNOTATIONS` - all `--annotation`s using in `docker build`
  - `_IMAGE_ANNOTATIONS` - found annotations for an image in registry

  ([#452](https://github.com/crashappsec/chalk/pull/452))

- Docker base image keys:

  - `_OP_ARTIFACT_CONTEXT` - what is the context of the artifact.
    For `docker build` its either `build` or `base`.
  - `DOCKER_BASE_IMAGE_REGISTRY` - just registry of the base image
  - `DOCKER_BASE_IMAGE_NAME` - repo name within the registry
  - `DOCKER_BASE_IMAGE_ID` - image id (config digest) of the base image
  - `DOCKER_BASE_IMAGE_METADATA_ID` - id of the base image chalkmark
  - `DOCKER_BASE_IMAGE_CHALK`` - full chalkmark of base image
  - `_COLLECTED_ARTIFACTS` - similar to `_CHALKS` but reports collected
    information about potentially non-chalked artifacts such as the base image.
    If the base image is chalked it can be correlated with the build
    chalkmark via `METADATA_ID`. Otherwise both artifacts can be linked
    via the digest or the image id.

  ([#453](https://github.com/crashappsec/chalk/pull/453),
  [#463](https://github.com/crashappsec/chalk/pull/463))

- `_IMAGE_LAYERS` key which collects image layer digests as it is stored
  in the registry. This should allow to correlate base images by matching
  layer combinations from other images.
  ([#456](https://github.com/crashappsec/chalk/pull/456))

- `_DOCKER_USED_REGISTRIES` - Configurations about all used docker registires
  during chalk operation. For example:

  ```json
  {
    "_DOCKER_USED_REGISTIES" {
      "example.com:5044": {
        "url": "https://example.com:5044/v2/",
        "mirroring": "registry-1.docker.io",
        "source": "buildx",
        "scheme": "https",
        "http": false,
        "secure": true,
        "insecure": false,
        "auth": true,
        "www_auth": false,
        "pinned_cert_path": "/etc/buildkit/certs/example_com_5044/ca.crt",
        "pinned_cert": "-----BEGIN CERTIFICATE-----\n..."
      }
    }
  }
  ```

  ([#461](https://github.com/crashappsec/chalk/pull/461))

## 0.4.14

**Nov 11, 2024**

### Breaking Changes

- Changes in embed attestation provider configuration.
  Removed `attestation_key_embed.location` configuration.
  It is replaced with these configurations:

  - `attestation_key_embed.filename`
  - `attestation_key_embed.save_path`
  - `attestation_key_embed.get_paths`

  This allows to separate paths where `chalk setup` look-ups keys
  as well where chalk will save generated key.
  Also this allows to lookup keys relative to `chalk` binary
  which is better suited for CI workflows where it might not
  be desirable to add additional files in current working directory.
  ([#445](https://github.com/crashappsec/chalk/pull/445))

- `chalk setup` requires interactive shell to generate new
  key-material. This will avoid accidentally generating
  new keys in CI.
  ([#447](https://github.com/crashappsec/chalk/pull/447))

### Fixes

- When running `semgrep`, its always added to `PATH`,
  as otherwise semgrep is not able to find `pysemgrep` folder.
  ([#439](https://github.com/crashappsec/chalk/pull/439))
- Docker pushing non-chalked images did not report metsys
  plugin keys such as `_EXIT_CODE`, `_CHALK_RUN_TIME`.
  ([#438](https://github.com/crashappsec/chalk/pull/438))
- External tools for non-file artifacts (e.g. docker image)
  sent duplicate keys in both report-level as well as
  chalk-mark level. For example `SBOM` key with equivalent
  content was duplicated twice.
  ([#440](https://github.com/crashappsec/chalk/pull/440))
- Memory leak in HTTP wrappers in `nimutils`.
  This mostly manifested in `chalk exec` when heartbeats
  were enabled as roughly each heartbeat would increase
  memory footprint by ~1Mb.
  ([#443](https://github.com/crashappsec/chalk/pull/443))

### New Features

- `_EXEC_ID` key which is unique for each `chalk` execution
  for all commands while chalk process is alive.
  For example it will send consistent values for both
  `exec` and `heartbeat` reports hence allowing to tie
  both reports together.
- `heartbeat` report template. It is a minimal reporting
  template which is now used as the default report template
  for all heartbeat reports. Main purpose of heartbeat is
  to indicate liveliness hence such a minimal report.
  All other metadata should be collected as part of `exec`
  report instead.

## 0.4.13

**Oct 10, 2024**

### New Features

- `_OP_EXIT_CODE` key which reports external commands
  exit code such as for `chalk docker build`.
  ([#417](https://github.com/crashappsec/chalk/pull/417))
- `_OP_CLOUD_SYS_VENDOR` key for reporting sys vendor
  file content used to identity cloud provider.
  ([#418](https://github.com/crashappsec/chalk/pull/418))
- `FAILED_KEYS` and `_OP_FAILED_KEYS` - metadata keys
  which chalk could not collect metadata for.
  Each key contains:

  - `code` - short identifiable code of a known error
  - `message` - exact encountered error/exception message
  - `description` - human-readable description of the error
    with additional context how to potentially resolve it

  ([#422](https://github.com/crashappsec/chalk/pull/422))

- `_NETWORK_PARTIAL_TRACEROUTE_IPS` - collect local network
  subnet IPs even when running inside docker network-namespaced
  (not using `--network=host`) container
  ([#425](https://github.com/crashappsec/chalk/pull/425))
- `DOCKERFILE_PATH_WITHIN_VCTL` key reports the path of a
  `Dockerfile` relative to the VCS' project root.
  ([#426](https://github.com/crashappsec/chalk/pull/426))

## 0.4.12

**Aug 29, 2024**

### Breaking Changes

- Removing `attestation_key_backup` provider. It was an
  experimental service which is discontinued in favor
  of other attestation providers.
  ([#411](https://github.com/crashappsec/chalk/pull/411))

### Fixes

- `conffile` plugin was sending some empty keys vs skipping
  them during reporting. Now it has matching behavior to
  other plugins which ignores empty keys.
  ([#412](https://github.com/crashappsec/chalk/pull/412))
- AWS instance is determined from board_asset_tag file when
  present. This allows to report `_AWS_INSTANCE_ID` even
  when cloud metadata endpoint is not reachable.
  ([#413](https://github.com/crashappsec/chalk/pull/413))
- Reporting AWS Lambda functions ARN for non-us-east-1
  regions. Previously global STS AWS endpoint was used
  which cannot fetch STS get-caller-identity for other
  AWS regions.
  ([#414](https://github.com/crashappsec/chalk/pull/414))

## 0.4.11

**Aug 13, 2024**

### Fixes

- `docker` run-time host metadata collection was failing
  for non-build commands such as `docker push`.
  ([#399](https://github.com/crashappsec/chalk/pull/399))
- `procfs` plugin was throwing an exception while parsing
  `/proc/net/dev` to populate `_OP_IPV[4/6]_INTERFACES` keys.
  ([#399](https://github.com/crashappsec/chalk/pull/399))
- `_IMAGE_DIGEST` is sent for `docker push` when
  buildx is not available. Normally chalk needs to validate
  type of the manifest in the registry (image or list)
  which is currently done via `buildx imagetools`.
  When buildx is missing and the operation was `docker push`
  the pushed image can only be image manifest as only buildx
  supports list manifests.
  ([#401](https://github.com/crashappsec/chalk/pull/401))
- `_REPO_DIGESTS` was reported even when image digest was
  not known during buildx-enabled docker builds.
  ([#402](https://github.com/crashappsec/chalk/pull/402))
- `METADATA_ID` and `METADATA_HASH` were incorrectly
  computed for all `docker push` operations.
  ([#403](https://github.com/crashappsec/chalk/pull/403))

## 0.4.10

**Aug 5, 2024**

### Fixes

- Fixing `ENTRYPOINT` wrapping for empty-like definitions:

  - `ENTRYPOINT`
  - `ENTRYPOINT []`
  - `ENTRYPOINT [""]`
    Now chalk correctly parses and wraps as appropriate
    depending on the use of buildkit.

  ([#396](https://github.com/crashappsec/chalk/pull/396))

### Other

- Increasing cloud metadata endpoint collection timeout
  from 500ms to 1sec as in some cases it takes longer than
  500ms to get a response.
  ([#388](https://github.com/crashappsec/chalk/pull/388))
- Not showing `exec` report when chalk is running in
  interactive shell.
  ([#390](https://github.com/crashappsec/chalk/pull/390))
- Not showing any `chalk exec` logs when running in
  interactive shell.
  ([#394](https://github.com/crashappsec/chalk/pull/394))

## 0.4.9

**July 30, 2024**

### Fixes

- When base image is already wrapped by chalk, `ENTRYPOINT`
  was recursively wrapped which broke image runtime
  as it was always exiting with non-zero code.
  ([#385](https://github.com/crashappsec/chalk/pull/385))

### New Features

- `docker build` and `docker push` now use `mark_default`
  chalk template instead of `minimal`. As such basic
  metadata about the repository is now included by default
  in the chalk mark (e.g. `/chalk.json`) such as the
  repository origin and commit id.
  ([#380](https://github.com/crashappsec/chalk/pull/380))
- New chalk keys:

  - `DOCKER_TARGET` - name of the target being built in `Dockerfile`
  - `DOCKER_BASE_IMAGES` - breakdown of all base images across
    all sections of `Dockerfile`
  - `DOCKER_COPY_IMAGES` - breakdown of all external `COPY --from`
    across all sections of `Dockerfile`

  ([#382](https://github.com/crashappsec/chalk/pull/382))

## 0.4.8

**July 12, 2024**

### Fixes

- A chalk report would previously omit the `_OP_CLOUD_PROVIDER`
  and `_OP_CLOUD_PROVIDER_SERVICE_TYPE` keys when:

  - No other instance metadata key (e.g. `_GCP_INSTANCE_METADATA`
    or `_OP_CLOUD_PROVIDER_IP`) was subscribed.
  - The instance metadata service couldn't be reached, or
    returned invalid data.

  ([#362](https://github.com/crashappsec/chalk/pull/362),
  [#370](https://github.com/crashappsec/chalk/pull/370))

- `_OP_ERRORS` was missing any logs/errors from plugins.
  The key was collected by the `system` plugin which
  is executed first. The key is now populated by `metsys`
  plugin which is executed last.
  ([#369](https://github.com/crashappsec/chalk/pull/369))

## 0.4.7

**June 24, 2024**

### Fixes

- Docker build `--metadata-file` flag is only added when
  using `buildx >= 0.6.0`. In addition the flag is only added
  when using `docker >= 22` as docker aliased `docker build`
  to `docker buildx build` which allows to use buildx flags
  in normal build command.
  ([#357](https://github.com/crashappsec/chalk/pull/357))

## 0.4.6

**June 20, 2024**

### Fixes

- Chalk did not extract correct commit ID for git repos
  with `HEAD` being symbolic reference to an annotated tag.
  This usually happens via `git symbolic-ref HEAD`.
  ([#347](https://github.com/crashappsec/chalk/pull/347))
- Chalk misreported annotated git tag as not annotated.
  To ensure tag is up-to-date with origin, chalk refetches
  regular tags (not annotated) from origin. To customize
  this behavior use `git.refetch_lightweight_tags` config.
  ([#349](https://github.com/crashappsec/chalk/pull/349))
- Chalk docker build did not support remote git context
  which was neither a tag or a branch.
  For example:

  ```
  docker build https://github.com/user/repo.git#refs/pull/1/merge
  ```

  ([#351](https://github.com/crashappsec/chalk/pull/351))

- Chalk did not correctly handle git annotated tags with an
  empty message.
  ([#354](https://github.com/crashappsec/chalk/pull/354))

## 0.4.5

**June 14, 2024**

### Fixes

- Docker push of distroless image built without `buildx` could
  not extract chalk mark from the image.
  ([#338](https://github.com/crashappsec/chalk/pull/338))
- Chalk did not handle git branch names with `/` in them
  and therefore could not report correct
  branch name/commit id.
  ([#340](https://github.com/crashappsec/chalk/pull/340))
- For packed repos (e.g. via `git gc`), chalk could not
  report all git-related keys like `COMMIT_ID`, `TAG`, etc.
  ([#341](https://github.com/crashappsec/chalk/pull/341))

### New Features

- Added `BUILD_COMMIT_ID` key. This reports the commit ID
  which triggered the build in CI/CD.
  ([#339](https://github.com/crashappsec/chalk/pull/339))

## 0.4.4

**June 12, 2024**

### Fixes

- `chalk exec` did not pass full executable being
  execed in arguments in `execv()` syscall.
  This broke distro-less Python images which used
  virtualenv as `sys.executable` wasn't virtual env
  python but instead was system python path.
  ([#333](https://github.com/crashappsec/chalk/pull/333))

## 0.4.3

**June 10, 2024**

### Fixes

- `BUILD_URI` for GitHub actions now includes run attempt
  in the URI. Previously `BUILD_URI` always linked to
  latest attempt.
  ([#320](https://github.com/crashappsec/chalk/pull/320))
- Building Docker image on top of previously wrapped chalked
  base image, `/chalk.json` now correctly indicates it is
  not the original wrapped base image.
  Previously `chalk exec` would report chalk mark from
  `/chalk.json` which was from the base image which is
  not expected.
  ([#322](https://github.com/crashappsec/chalk/pull/322))
- Docker build without `buildx` was failing for distroless
  images with non-root `USER`.
  ([#323](https://github.com/crashappsec/chalk/pull/323))

## 0.4.2

**June 5, 2024**

### Fixes

- When building Chalk on macOS, downloading root certs
  could fail due to missing quotes around the URL
  ([nimutils #68](https://github.com/crashappsec/nimutils/pull/68))
- Regression:`chalk load` did not revalidate previously loaded
  components in Chalk since >=0.4.0
  ([#313](https://github.com/crashappsec/chalk/pull/313))
- The external tool `semgrep` now correctly scans the
  Chalk context folder. Previously, it always scanned the
  current working directory, which produced incorrect
  scans when the Docker context was outside that
  directory.
  ([#314](https://github.com/crashappsec/chalk/pull/314))
- Without Buildx, Docker failed to wrap `ENTRYPOINT` when
  the Docker context folder already had a file/directory named
  `chalk` or `docker`.
  ([#315](https://github.com/crashappsec/chalk/pull/315))
- With Buildx, Docker failed to wrap `ENTRYPOINT` when
  a `chalk` binary was located next to `.dockerignore`
  (e.g. in the Chalk repo itself) because `chalk` could
  not be copied during the build.
  ([#315](https://github.com/crashappsec/chalk/pull/315))

### New Features

- New chalk keys:

  - New key holding GCP project metadata: `_GCP_PROJECT_METADATA`
    ([#311](https://github.com/crashappsec/chalk/pull/31))

- The Chalk external tools `syft` and `semgrep` are now run via Docker
  when they are not installed and Docker is available. This avoids the
  need to install them on the host system.
  ([#314](https://github.com/crashappsec/chalk/pull/314))

## 0.4.1

**May 30, 2024**

### Fixes

- Fixed metadata reporting for GCP cloud run services
  ([#304](https://github.com/crashappsec/chalk/pull/304))
- Fixes custom key name validation
  ([#307](https://github.com/crashappsec/chalk/pull/307))

### New Features

- New chalk keys:

  - Keys to identify the origin repository, using
    an identifier provided by the CI/CD system:

    - `BUILD_ORIGIN_ID`
    - `BUILD_ORIGIN_KEY`
    - `BUILD_ORIGIN_OWNER_ID`
    - `BUILD_ORIGIN_OWNER_KEY`

  ([#303](https://github.com/crashappsec/chalk/pull/303))

## 0.4.0

**May 28, 2024**

### Breaking Changes

- Removed chalk keys:

  - `_IMAGE_VIRTUAL_SIZE` - deprecated by docker
  - `_IMAGE_LAST_TAG_TIME` - scoped to local daemon and is
    not shared with buildx. Many images report as
    `0001-01-01T00:00:00Z`
  - `_IMAGE_STORAGE_METADATA` - metadata of a docker storage
    driver and is not directly related to docker image
  - `DOCKER_CHALK_TEMPORARY_TAG` - chalk no longer adds
    temporary tag to docker builds
  - `_SIGNATURE` - cosign generates unique signature
    per registry. New key is `_SIGNATURES`.
  - `_OP_HOSTINFO` - renamed to `_OP_HOST_VERSION`
  - `_OP_NODENAME` - renamed to `_OP_HOST_NODENAME`
  - `HOSTINFO_WHEN_CHALKED` - renamed to `HOST_VERSION_WHEN_CHALKED`
  - `NODENAME_WHEN_CHALKED` - renamed to `HOST_NODENAME_WHEN_CHALKED`

  ([#266](https://github.com/crashappsec/chalk/pull/266),
  [#282](https://github.com/crashappsec/chalk/pull/282),
  [#284](https://github.com/crashappsec/chalk/pull/284),
  [#286](https://github.com/crashappsec/chalk/pull/286))

- Changed chalk keys:

  - `DOCKER_CHALK_ADDED_TO_DOCKERFILE` - is now a list
    vs a single string
  - `_IMAGE_STOP_SIGNAL` - is now a string vs an int.
    Docker always reported stop signal as string.
    This was a mistake in field definition.

  ([#282](https://github.com/crashappsec/chalk/pull/282))

- Removed configurations:

  - `extract.search_base_layers_for_marks` - chalk mark
    is not guaranteed to be top layer in all cases.
    For example it is not top layer without buildx.
    Therefore all layers must be searched.
  - `load.update_arch_binaries` - docker multi-platform
    builds ensure config is loaded into multi-arch chalk
    binaries and therefore it is not needed to pre-load
    any configurations at load time. This also removed
    `chalk load --update-arch-binaries` flag.

  ([#282](https://github.com/crashappsec/chalk/pull/282),
  [#286](https://github.com/crashappsec/chalk/pull/286))

- `push_default` reporting template is removed as `push`
  is now a top-level chalkable operation and therefore
  it now uses `insertion_default` template.
  ([#282](https://github.com/crashappsec/chalk/pull/282))

- When loading custom configs with `chalk load`, metadata
  collection is disabled for all plugins except for
  required chalk plugins.
  ([#286](https://github.com/crashappsec/chalk/pull/286))

### Fixes

- Fixed not being able to wrap docker builds when using
  `scratch` as base image.
  ([#266](https://github.com/crashappsec/chalk/pull/266))
- Docker ENTRYPOINT wrapping base image inspection works
  without requiring buildx.
  ([#282](https://github.com/crashappsec/chalk/pull/282))
- Docker builds without buildx could fail when base image
  specified `USER`.
  ([#285](https://github.com/crashappsec/chalk/pull/285))
- Tech stack plugin will hang when running chalk from
  `/` as it would attempt to scan things like `/dev/random`.
  ([#286](https://github.com/crashappsec/chalk/pull/286))
- Docker wrapping was resetting image `CMD` when base
  image had `ENTRYPOINT` defined.
  ([#286](https://github.com/crashappsec/chalk/pull/286))
- GCP instance metadata collection does not work by DNS
  name reliably so switched to hard-coded IP.
  ([#293](https://github.com/crashappsec/chalk/pull/293))

### New Features

- Chalk docker builds now fully support manifest lists.
  This affects all commands which produce manifest lists
  such as multi-platform builds and new features like
  `--provenance=true` and `--sbom=true`.
  ([#282](https://github.com/crashappsec/chalk/pull/282))
- New Chalk keys:

  - `_IMAGE_COMPRESSED_SIZE` - compressed docker image size
    when collecting image metadata directly from the registry
  - `DOCKER_PLATFORMS` - all platforms used in docker build
  - `DOCKER_FILE_CHALKED` - post-chalk Dockerfile content
    as it is built
  - Docker base image fields:
    - `DOCKER_BASE_IMAGE` - base image used in Dockerfile
    - `DOCKER_BASE_IMAGE_REPO` - just the repo name
    - `DOCKER_BASE_IMAGE_TAG` - just the tag
    - `DOCKER_BASE_IMAGE_DIGEST` - just the digest
  - Docker versions and general information:
    - `_DOCKER_CLIENT_VERSION`
    - `_DOCKER_SERVER_VERSION`
    - `_DOCKER_BUILDX_VERSION`
    - `_DOCKER_INFO` - output of `docker info`
    - `_DOCKER_BUILDER_BUILDKIT_VERSION`
    - `_DOCKER_BUILDER_INFO` - output of `docker buildx inspect <builder>`
  - `_IMAGE_DIGEST` - docker registry v2 image manifest digest
  - `_IMAGE_LIST_DIGEST` - docker registry v2 image list manifest digest
  - `_IMAGE_PROVENANCE` - provenance JSON when image was built with
    `--provenance=true`
  - `_IMAGE_SBOM` - SBOM JSON when image was built with
    `--sbom=true`
  - `_SIGNATURES` - all docker registry cosign signatures
  - All `uname()` fields have dedicated fields:
    - `HOST_SYSNAME_WHEN_CHALKED`
    - `HOST_NODENAME_WHEN_CHALKED`
    - `HOST_RELEASE_WHEN_CHALKED`
    - `HOST_VERSION_WHEN_CHALKED`
    - `HOST_MACHINE_WHEN_CHALKED`
    - `_OP_HOST_SYSNAME`
    - `_OP_HOST_NODENAME`
    - `_OP_HOST_RELEASE`
    - `_OP_HOST_VERSION`
    - `_OP_HOST_MACHINE`
  - All git keys now are also sent as run time host keys.
    This allows to report from what repo the report is
    running even if its different from repos of individual
    chalk marks or when there are no chalk marks.

    - `_ORIGIN_URI`
    - `_BRANCH`
    - `_TAG`
    - `_TAG_SIGNED`
    - `_COMMIT_ID`
    - `_COMMIT_SIGNED`
    - `_AUTHOR`
    - `_DATE_AUTHORED`
    - `_COMMITTER`
    - `_DATE_COMMITTED`
    - `_COMMIT_MESSAGE`
    - `_TAGGER`
    - `_DATE_TAGGED`
    - `_TAG_MESSAGE`

  ([#266](https://github.com/crashappsec/chalk/pull/266),
  [#282](https://github.com/crashappsec/chalk/pull/282),
  [#284](https://github.com/crashappsec/chalk/pull/284),
  [#286](https://github.com/crashappsec/chalk/pull/286))

- Docker build `cosign` attestation is pushed to each tagged
  registry. As a result attestations can be validated from any
  registry when pulling images.
  ([#284](https://github.com/crashappsec/chalk/pull/284))
- `docker`/`buildx`/`cosign` versions are now printed
  in `chalk version` command.
  ([#282](https://github.com/crashappsec/chalk/pull/282))
- New command for dumping all user configurations as json
  as well as corresponding load all flag to import them:

  ```sh
  chalk dump all | chalk load --replace --all -
  ```

  ([#286](https://github.com/crashappsec/chalk/pull/286))

- Docker multi-platform builds now automatically downloads
  corresponding chalk binary for other architectures
  if not already present on disk.

  ([#286](https://github.com/crashappsec/chalk/pull/286))

- New chalk configurations:

  - `docker.arch_binary_locations_path` - path where to
    auto-discover chalk binary locations for docker
    multi-platform builds.
  - `docker.download_arch_binary` - whether to automatically
    download chalk binaries for other architectures.
  - `docker.download_arch_binary_urls` - URL template where
    to download chalk binaries.
  - `docker.install_binfmt` - for multi-platform builds
    automatically install binfmt when not all platforms
    are supported by the buildx builder

  ([#286](https://github.com/crashappsec/chalk/pull/286))

- `--skip-custom-reports` flag. Together with
  `--skip-command-report` allows to completely disable
  chalk reporting. Note that metadata collection
  is still going to happen as metadata still needs
  to be inserted into a chalkmark. Just no report about
  the operation is going to be omitted.
  ([#286](https://github.com/crashappsec/chalk/pull/286))

## 0.3.5

**Apr 05, 2024**

### Breaking Changes

- S3 sinks must now specify the bucket region. Previously
  it defaulted to `us-east-1` if the `AWS_REGION` or
  `AWS_DEFAULT_REGION` environment variables were not set
  ([#246](https://github.com/crashappsec/chalk/pull/246))

### Fixes

- The Docker codec is now bypassed when `docker` is not
  installed. Previously, any chalk sub-scan such as
  during `chalk exec` had misleading error logs.
  ([#248](https://github.com/crashappsec/chalk/pull/248))
- `chalk docker ...` now exits with a non-zero exit code
  when `docker` is not installed.
  ([#256](https://github.com/crashappsec/chalk/pull/256))
- Fixed parsing CLI params when wrapping `docker`
  (rename `chalk` exe to `docker`) and a docker command
  had a "docker" param.
  ([#257](https://github.com/crashappsec/chalk/pull/257))

## 0.3.4

**Mar 18, 2024**

### Breaking Changes

- Attestation key generation/retrieval was refactored
  to use key providers. As such, all previous config
  values related to signing backup service have changed.

  Removed attributes:

  - `use_signing_key_backup_service`
  - `signing_key_backup_service_url`
  - `signing_key_backup_service_auth_config_name`
  - `signing_key_backup_service_timeout`
  - `signing_key_location`

  Instead now each individual key provider can be separately
  configured:

  ```
  attestation {
    key_provider: "embed" # or "backup" which enables key backup provider
                          # as previously configured by
                          # `use_signing_key_backup_service`
    attestation_key_embed {
      location: "./chalk." # used to be `signing_key_location`
    }
    attestation_key_backup {
      location: "./chalk."    # used to be `signing_key_location`
      uri:      "https://..." # used to be `signing_key_backup_service_url`
      auth:     "..."         # used to be `signing_key_backup_service_auth_config_name`
      timeout:  << 1 sec >>   # used to be `signing_key_backup_service_timeout`
    }
  }
  ```

  ([#239](https://github.com/crashappsec/chalk/pull/239))

### Fixes

- Docker build correctly wraps `ENTRYPOINT` when base
  image has it defined.
  ([#147](https://github.com/crashappsec/chalk/pull/147))
- Fixes a segfault when using secrets backup service
  during `chalk setup`.
  ([#220](https://github.com/crashappsec/chalk/pull/220))
- Honoring cache component cache on chalk conf load.
  ([#222](https://github.com/crashappsec/chalk/pull/222))
- Fixes a segfault when accidentally providing `http://`
  URL to a sink instead of `https://`.
  ([#223](https://github.com/crashappsec/chalk/pull/223))
- Fixes leaking FDs which didn't allow to chalk large
  zip files such as large Java jar file.
  ([#229](https://github.com/crashappsec/chalk/pull/229))
- Fixes chalking zip file reporting git-repo keys.
  ([#230](https://github.com/crashappsec/chalk/issues/230))
- Fixes cosign not honoring `CHALK_PASSWORD` in all operations.
  ([#232](https://github.com/crashappsec/chalk/pull/232))
- Git plugin did not parse some git objects correctly
  which in some cases misreported git keys.
  ([#241](https://github.com/crashappsec/chalk/pull/241))
- Fixes `chalk load` not honoring default parameter
  value after any incorrect previous value was provided
  ([#242](https://github.com/crashappsec/chalk/pull/242))

### New Features

- `memoize` con4m function which allows caching function
  callback result into chalk mark for future lookups.
  ([#239](https://github.com/crashappsec/chalk/pull/239))
- `auth_headers` con4m function which allows getting auth
  headers for a specific auth config.
  ([#239](https://github.com/crashappsec/chalk/pull/239))
- `parse_json` con4m function which parses JSON string.
  ([#239](https://github.com/crashappsec/chalk/pull/239))
- `get` attestation key provider which allows to retrieve
  key-material over API.
  ([#239](https://github.com/crashappsec/chalk/pull/239))
- `chalk exec` does not require `--exec-command-name`
  and can get command name to exec directly from args:

  ```bash
  chalk exec -- echo hello
  ```

  ([#155](https://github.com/crashappsec/chalk/pull/155))

## 0.3.3

**Feb 26, 2024**

### New Features

- Chalk can now write two new keys to chalk marks and reports:

  - `COMMIT_MESSAGE`: the entire commit message of the most
    recent commit.
  - `TAG_MESSAGE`: the entire tag message of an annotated tag,
    if the current repo state has such a tag.

  If the commit or tag is signed, the `COMMIT_MESSAGE` or
  `TAG_MESSAGE` value does not contain the signature.
  ([#211](https://github.com/crashappsec/chalk/pull/211))

- Chalk falls back to bundled Mozilla CA Store when there
  are no system TLS certs to use (e.g. busybox container).
  ([#196](https://github.com/crashappsec/chalk/pull/196))

### Fixes

- Fixes possible exception when signing backup service
  would return non-json response
  ([#189](https://github.com/crashappsec/chalk/pull/189))
- Signing key backup service is only called for chalk
  commands which require cosign private key -
  insert/build/push.
  As a result other commands such as `exec` do not interact
  with the backup service.
  ([#191](https://github.com/crashappsec/chalk/pull/191))
- Fixing docker build attempting to use `--build-context`
  on older docker versions which did not support that flag.
  ([#207](https://github.com/crashappsec/chalk/pull/207))
- Fixes `echo foo | chalk docker login --password-stdin`
  as `stdin` was not being closed in the pipe to docker
  process.
  ([#209](https://github.com/crashappsec/chalk/pull/209))

## 0.3.2

**Feb 2, 2024**

### Fixes

- Fixes a typo in `chalk version` for the build date.
  ([#148](https://github.com/crashappsec/chalk/pull/148))
- `TERM=dump` renders without colors
  ([#163](https://github.com/crashappsec/chalk/pull/163))
- `AWS_REGION` env var is honored in `s3` sinks
  ([#164](https://github.com/crashappsec/chalk/pull/164))
- Show GitHub chalk report on `chalk extract`
  ([#166](https://github.com/crashappsec/chalk/pull/166))
- `chalk help docgen` shows help for `docgen` command
  ([#173](https://github.com/crashappsec/chalk/pull/173))
- `chalk load` would duplicate already loaded components
  in the config
  ([#176](https://github.com/crashappsec/chalk/pull/176))
- `chalk setup` would not honor existing keys, if present
  ([#184](https://github.com/crashappsec/chalk/pull/184))

## 0.3.1

**Jan 23, 2024**

### Breaking Changes

- Remove the `--no-api-login` option.
  ([#137](https://github.com/crashappsec/chalk/pull/137))

### New Features

- Add support for arm64 Linux once again.
  It was omitted from the Chalk 0.3.0 release.

### Fixes

- Fix some rendering bugs.

### Known Issues

- If a docker base image has `ENTRYPOINT` defined,
  `docker.wrap_cmd` will break it as it overwrites
  its own `ENTRYPOINT`. Next release will correctly
  its own `ENTRYPOINT`. A later release will correctly
  inspect all base images and wrap `ENTRYPOINT` correctly.

- This release does not support x86_64 macOS.
  It will be supported once again in a later release.

## 0.3.0

**Jan 15, 2024**

### Breaking Changes

- `_OP_CLOUD_METADATA` is now a JSON object vs a string
  containing JSON data. In addition cloud metadata is now
  nested to allow to include more metadata about running
  cloud instances.
  ([#112](https://github.com/crashappsec/chalk/pull/112))

- The signing key backup service has been completely overhauled and
  no longer uses the OIDC Device Code Flow to authenticate to the API.
  Instead a pre-generated API access token is passed in chalk profile
  and that value is used as the bearer token. The `setup` command
  still generates keys for signing but will no longer prompt with a
  QR code to authenticate to the API.

- As a result of the above the `login` and `logout` commands have been
  removed.

- A number of signing key backup related configuration values and variables
  have had their names changed to be more description:
  - `CHALK_API_KEY` -> `CHALK_DATA_API_KEY`
  - `use_secret_manager` -> `use_signing_key_backup_service`
  - `secret_manager_url` -> `signing_key_backup_service_url`
  - `secret_manager_timeout` -> `signing_key_backup_service_timeout`

### New Features

- Adding support for git context for docker build commands.
  ([#86](https://github.com/crashappsec/chalk/pull/86))
- Adding new git metadata fields about:

  - authored commit
  - committer
  - tag

  ([#86](https://github.com/crashappsec/chalk/pull/86),
  [#89](https://github.com/crashappsec/chalk/pull/89))

- Improved pretty printing for various commands
  ([#99](https://github.com/crashappsec/chalk/pull/99))
- Added `github_json_group` for printing chalk marks
  in GitHub Actions.
  ([#86](https://github.com/crashappsec/chalk/pull/86))
- Adding `presign` sink to allow uploads to S3 without
  hard-coded credentials in the chalk configuration.
  ([#103](https://github.com/crashappsec/chalk/pull/103))
- Adding JWT/Basic auth authentication options to sinks.
  ([#111](https://github.com/crashappsec/chalk/pull/111))
- Adding `docker.wrap_cmd` to allow to customize whether
  `CMD` should be wrapped when `ENTRYPOINT` is missing
  in `Dockerfile`.
  ([#112](https://github.com/crashappsec/chalk/pull/112))
- Adding minimal AWS lambda metadata collection.
  It includes only basic information about lambda function
  such as its ARN and its runtime environment.
  ([#112](https://github.com/crashappsec/chalk/pull/112))
- Adding experimental support for detection of technologies used at chalk and
  runtime (programming languages, databases, servers, etc.)
  ([#128](https://github.com/crashappsec/chalk/pull/128))

### Fixes

- Fixes docker version comparison checks.
  As a result buildx is correctly detected now for >=0.10.
  ([#86](https://github.com/crashappsec/chalk/pull/86))
- Subprocess command output was not reliable being captured.
  ([#93](https://github.com/crashappsec/chalk/pull/93))
- Fixes automatic installation of `semgrep` when SAST is enabled.
  ([#94](https://github.com/crashappsec/chalk/pull/94))
- Ensuring chalk executable has correct permissions.
  Otherwise reading embedded configuration would fail in some cases.
  ([#104](https://github.com/crashappsec/chalk/pull/104))
- Pushing all tags during `docker build --push -t one -t two ...`.
  ([#110](https://github.com/crashappsec/chalk/pull/110))
- Sending `_ACTION_ID` during `push` command.
  ([#116](https://github.com/crashappsec/chalk/pull/116))
- All component parameters are saved in the chalk mark.
  ([#126](https://github.com/crashappsec/chalk/pull/126))
- Gracefully handling permission issues when chalk is running
  as non-existing user. This is most common in lambda
  which runs as user `993`.
  ([#112](https://github.com/crashappsec/chalk/pull/112))
- `CMD` wrapping supports wrapping shell scripts
  (e.g. `CMD set -x && echo hello`).
  ([#132](https://github.com/crashappsec/chalk/pull/132))

### Known Issues

- If a docker base image has `ENTRYPOINT` defined,
  `docker.wrap_cmd` will break it as it overwrites
  its own `ENTRYPOINT`. A later release will correctly
  inspect all base images and wrap `ENTRYPOINT` correctly.
- This release does not support:

  - Mac x86_64 builds
  - Linux aarch64 builds

  Support for these platforms will be added back in the future.

## 0.2.2

**Oct 30, 2023**

### New Features

- Adding support for docker multi-platform builds.
  ([#54](https://github.com/crashappsec/chalk/pull/54))

### Fixes

- Honoring Syft/SBOM configs during docker builds.
  ([#84](https://github.com/crashappsec/chalk/pull/84))

## 0.2.1

**Oct 25, 2023**

### Fixes

- Component parameters can set config attributes.
  ([#75](https://github.com/crashappsec/chalk/issues/75))

## 0.2.0

**Oct 20, 2023**

### New Features

- Added a module so that most users can easily install complex
  configurations without editing any configuration information
  whatsoever. Modules can be loaded from https URLs or from the local
  file system. Our recipes will host modules on chalkdust.io.

  Modules can have parameters that you provide when installing them,
  and can have arbitrary defaults (for instance, any module importing
  the module for connecting to our demo web server defaults to your
  current IP address).

  We do extensive conflict checking to ensure that modules that are
  incompatible will not run (and generally won't even load).

  We will eventually do an in-app UI to browse and install modules.
  ([#47](https://github.com/crashappsec/chalk/pull/47))
  ([#67](https://github.com/crashappsec/chalk/pull/67))

- Added initial metadata collection for GCP and Azure, along with a
  metadata key to provide the current cloud provider, and a key that
  distinguishes the cloud provider's environments. Currently, this
  only does AWS (EKS, ECS, EC2).
  ([#59](https://github.com/crashappsec/chalk/pull/59))
  ([#65](https://github.com/crashappsec/chalk/pull/65))

- Added OIDC token refreshing, along with `chalk login` and
  `chalk logout` commands to log out of auth for the secret manager.
  ([#51](https://github.com/crashappsec/chalk/pull/51))
  [#55](https://github.com/crashappsec/chalk/pull/55),
  [#60](https://github.com/crashappsec/chalk/pull/60))

- The initial rendering engine work was completed. This means
  `chalk help`, `chalk help metadata` are fully functional. This engine is
  effectively most of the way to a web browser, and will enable us to
  offload a lot of the documentation, and do a little storefront (once
  we integrate in notcurses).
  ([#58](https://github.com/crashappsec/chalk/pull/58))

- If you're doing multi-arch binary support, Chalk can now pass your
  native binary's configuration to other arches, though it does
  currently re-install modules, so the original module locations need
  to be available.

### Fixes

- Docker support when installed via `Snap`.
  ([#9](https://github.com/crashappsec/chalk/pull/9))
- Removes error log when using chalk on ARM Linux as chalk fully
  runs on ARM Linux now.
  ([#7](https://github.com/crashappsec/chalk/pull/7))
- When a `Dockerfile` uses `USER` directive, chalk can now wrap
  entrypoint in that image
  (`docker.wrap_entrypoint = true` in chalk config).
  ([#34](https://github.com/crashappsec/chalk/pull/34))
- Segfault when running chalk operation (e.g. `insert`) in empty
  git repo without any commits.
  ([#39](https://github.com/crashappsec/chalk/pull/39))
- Sometimes Docker build would not wrap entrypoint.
  ([#45](https://github.com/crashappsec/chalk/pull/45))
- Cosign now only gets installed if needed.
  ([#49](https://github.com/crashappsec/chalk/pull/49))
- Docker `ENTRYPOINT`/`COMMAND` wrapping now preserves all named
  arguments from original `ENTRYPOINT`/`COMMAND`.
  (e.g. `ENTRYPOINT ["ls", "-la"]`)
  ([#70](https://github.com/crashappsec/chalk/issues/70))

### Known Issues

- There are still embedded docs that need to be fixed now that the
  entire rendering engine is working well enough.

- When a `Dockerfile` does not use the `USER` directive but base image
  uses it to change default image user, chalk cannot wrap the image as
  it on legacy Docker builder (not buildx) as it will fail to `chmod`
  permissions of chalk during the build.

## 0.1.2

**Sept 26, 2023**

This is the first open source release of Chalk. For those who
participated in the public preview, there have been massive changes
from those releases, based on your excellent feedback. There's a
summary of those changes below.

### Known Issues

At release time, here are known issues:

#### Documentation

- We have not yet produced any developer documentation. We will do so
  soon.

- The in-command `help` renderer did not get finished before
  release. Everything should display, but the output will have some
  obvious problems (spacing, wrapping, formatting choices, etc). If
  it's insufficient, use the online docs, which use the same core
  source material.

#### Containers

- Our support for container marking is currently limited to Docker.

- Chalk does not yet have any awareness of `docker compose`, `bake` or
  similar frameworks atop Docker. We only process containers created
  via direct docker invocation that's wrapped by chalk.

- Similarly, Chalk does not yet capture any metadata around
  orchestration layers like Kubernetes or cloud-provider managed
  container solutions.

- Chalk does not yet handle Docker HEREDOCs (which we've found aren't
  yet getting heavy use).

- Chalk currently will refuse to automatically wrap or sign
  multi-architecture builds. It still will produce the desired
  container with a chalk mark, however.

#### OS / Hardware support

- We are not supporting running chalk on Windows at this time (even
  under WSL2).

- In fact, Linux and Mac on the two major hardware architectures are
  the only platforms we are currently supporting. More Posix platforms
  _may_ work, but we are making no effort there at this point.

#### Data collection and Marking

- We currently do not handle any form of PE binaries, so do not chalk
  .NET or other Windows applications.

- There are other platforms we hope to mark that we don't yet support;
  see the roadmap section below.

#### Other

- The bash autocomplete script installation a Mac, but because it's not
  a zsh script, it will not autocomplete file arguments, etc.

- The signing functionality does download the `cosign` binary if not
  present and needed; this can take a bit of time, and should
  eventually be replaced with a native in-toto implementation.

- Dy default, Chalk uses an advisory file lock to avoid overlapping
  writes to files by multiple chalk instances (particularly meant for
  protecting log files). This can lead to chalk instances giving up on
  obtaining the lock if you run multiple instances in the same
  environment at once.

### Major changes since the preview releases

- We've added automatic signing; run `chalk setup`; if you create a
  free account for our secret service, it'll generate a keypair for
  you, encrypt the private key, and automatically sign whenever
  possible. If you don't want to use the service, you'll have to
  provide a secret via environment variable, and should run setup with
  the `--no-api-login` flag.

- We added automatic wrapping of container entry points, so that you
  can get beacon data when containers start up (via the `chalk exec`
  command).

- We've additionally added the ability to have `chalk exec` send
  periodic `heartbeat` reports, so you can collect metadata about
  runtime workloads after startup.

- There were several config file format changes based on
  feedback. Please contact us if you want help migrating, but things
  are even easier now.

- ELF Chalk marks are now put into their own ELF section in the
  binary, so they will survive a `strip` operation.

- We added / changed a number of metadata keys around Docker images
  and containers, and enhanced the interface for extracting data from
  containers.

- We added an AWS IMDSv2 collection module, and associated metadata
  keys.

- We added proc file system collection module.

- We are now officially supporting ARM Linux builds and MacOS (arm and
  amd64) builds of Chalk.

- You can inject environment variables into docker images (previously
  we only supported labels)

- Linux builds will now always fully statically compile with
  MUSL-built shared libraries. On the Mac, `libc` is still dynamically
  loaded.

### Roadmap Items

We are actively developing Chalk, and listening closely to the people
already using it. Below are a number of key items in our backlog that
we're considering. However, we have made no decisions on the order
we'll work on these things, and may add or drop items from the
list. For a more up-to-date view, please check our issues list in
GitHub.

All of the below are targets for our Open Source; we also will soon be
releasing services around Chalk (with a free tier).

- A TUI (using Python 3) to make it very easy to build custom
  configurations for most needs, without having to touch a
  configuration file.

- On-demand data collection from runtime environments (via triggers).

- Heartbeat reports should be more flexible, to only report when some
  sort of condition(s) is(/are) met (both per-metadata key, and
  per-report).

- Many changes / enhancements to make to the underlying configuration
  file format to benefit Chalk and its users.

- Data collection modules for other cloud providers.

- Data collection modules for orchestration systems, particularly k8s.

- A `chalk log` command that can pretty-print (and search?) log
  entries from any readable source you configure (not just the default
  log file).

- Better handling for multi-architecture builds.

- Wrapping / data collection for `docker compose` and `docker bake`

- Better OS X support (right now, it's just good enough for us to
  develop on; Linux is the primary target)

- More off-the-shelf integrations (including third party tools)

- Support for CI/CD data collection modules that are longer-running
  (requiring them to work on a copy of the dev or build environment)

- Chalk mark support for in-the-browser JavaScript (we have an
  approach we know works, we just need to build it out).

- Better support for specific platforms for serverless apps.

Note that Windows support is _not_ a priority for us currently. We'd
love to get there eventually, but do not expect to get to it any time
soon, unless contributed by the community.
