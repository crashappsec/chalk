# Chalk Release Notes

## On the `main` branch

### Fixes

- When building Chalk on macOS, downloading root certs
  could fail due to missing quotes around the URL
  ([nimutils #68](https://github.com/crashappsec/nimutils/pull/68))

### New Features

- New chalk keys:

  - New key holding GCP project metadata: `_GCP_PROJECT_METADATA`
    ([#311](https://github.com/crashappsec/chalk/pull/31))

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

- When loading custom configs with `chalk load`, metdata
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
  only does AWS (eks, ecs, ec2).
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
