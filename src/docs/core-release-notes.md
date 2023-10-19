# Release Notes for Chalk version 0.1.3 (Oct 19, 2023)

## New Features

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
  [47](https://github.com/crashappsec/chalk/pull/47)
  [67](https://github.com/crashappsec/chalk/pull/67)

- Added initial metadata collection for GCP and Azure, along with a
  metadata key to provide the current cloud provider, and a key that
  distinguishes the cloud provider's environments. Currently, this
  only does AWS (eks, ecs, ec2).
  [59](https://github.com/crashappsec/chalk/pull/59)
  [65](https://github.com/crashappsec/chalk/pull/65)

- Added OIDC token refreshing, along with `chalk login` and
  `chalk logout` commands to log out of auth for the secret manager.
  [51](https://github.com/crashappsec/chalk/pull/51)
  [55](https://github.com/crashappsec/chalk/pull/55)
  [60](https://github.com/crashappsec/chalk/pull/60)

- The initial rendering engine work was completed. This means
  `chalk help`, `chalk help metadata` are fully functional. This engine is
  effectively most of the way to a web browser, and will enable us to
  offload a lot of the documentation, and do a little storefront (once
  we integrate in notcurses).
  [58](https://github.com/crashappsec/chalk/pull/58)

- If you're doing multi-arch binary support, Chalk can now pass your
  native binary's configuration to other arches, though it does
  currently re-install modules, so the original module locations need
  to be available.

## Fixes

- Docker support when installed via `Snap`.
  [9](https://github.com/crashappsec/chalk/pull/9)
- Removes error log when using chalk on ARM Linux as chalk fully
  runs on ARM Linux now.
  [7](https://github.com/crashappsec/chalk/pull/7)
- When a `Dockerfile` uses `USER` directive, chalk can now wrap
  entrypoint in that image
  (`docker.wrap_entrypoint = true` in chalk config).
  [34](https://github.com/crashappsec/chalk/pull/34)
- Segfault when running chalk operation (e.g. `insert`) in empty
  git repo without any commits.
  [39](https://github.com/crashappsec/chalk/pull/39)
- Sometimes Docker build would not wrap entrypoint.
  [45](https://github.com/crashappsec/chalk/pull/45)
- Cosign now only gets installed if needed.
  [49](https://github.com/crashappsec/chalk/pull/49)
- Docker `ENTRYPOINT`/`COMMAND` wrapping now preserves all named
  arguments from original `ENTRYPOINT`/`COMMAND`.
  (e.g. `ENTRYPOINT ["ls", "-la"]`)
  [70](https://github.com/crashappsec/chalk/issues/70)

## Known Issues

- There are still embedded docs that need to be fixed now that the
  entire rendering engine is working well enough.

- When a `Dockerfile` does not use the `USER` directive but base image
  uses it to change default image user, chalk cannot wrap the image as
  it on legacy Docker builder (not buildx) as it will fail to `chmod`
  permissions of chalk during the build.

# Release Notes for Chalk version 0.1.2 (Sept 26, 2023)

This is the first open source release of Chalk. For those who
participated in the public preview, there have been massive changes
from those releases, based on your excellent feedback. There's a
summary of those changes below.

## Known Issues

At release time, here are known issues:

### Documentation

- We have not yet produced any developer documentation. We will do so
  soon.

- The in-command `help` renderer did not get finished before
  release. Everything should display, but the output will have some
  obvious problems (spacing, wrapping, formatting choices, etc). If
  it's insufficient, use the online docs, which use the same core
  source material.

### Containers

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

### OS / Hardware support

- We are not supporting running chalk on Windows at this time (even
  under WSL2).

- In fact, Linux and Mac on the two major hardware architectures are
  the only platforms we are currently supporting. More Posix platforms
  _may_ work, but we are making no effort there at this point.

### Data collection and Marking

- We currently do not handle any form of PE binaries, so do not chalk
  .NET or other Windows applications.

- There are other platforms we hope to mark that we don't yet support;
  see the roadmap section below.

### Other

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

## Major changes since the preview releases

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

## Roadmap Items

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
