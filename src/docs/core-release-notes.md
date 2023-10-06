# Release Notes for Chalk version 0.1.3

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

## Known Issues

### Containers

- When a `Dockerfile` does not use `USER` directive but base image
  uses it to change default image user, chalk cannot wrap the
  image as it on legacy Docker builder (not buildx) as it will
  fail to `chmod` permissions of chalk during the build.

# Release Notes for Chalk version 0.1.2

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

- Chalk currently will refuse to automaticlly wrap or sign
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

- The bash autocomplete script installson a Mac, but because it's not
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
we're considering. However, we have made no descisions on the order
we'll work on these things, and may add or drop items from the
list. For a more up-to-date view, please check our issues list in
Github.

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
