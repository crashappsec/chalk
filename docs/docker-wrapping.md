# How Chalk Wraps Docker

## Introduction

Chalk’s main goal is to collect metadata about how container images are built
and where are they used. Both can boil down to collecting contextual metadata
about where these operations are executed:

- Build an image:

  ```bash
  docker build ... -t myimage
  ```

- Use/deploy previously built image

  ```bash
  docker run ... myimage
  ```

As building normally happens in CI/CD, useful metadata to collect there may include:

- time of the build
- metadata about the CI runner
- metadata about the git repo being used to built an image
- results of other tools ran against the repo
  (e.g. SBOM via `syft`, SAST via `semgrep`, etc)
- metadata about the base image
- metadata about the built image
- metadata about registries where image was pushed

On the other hand deploying the image will have other useful metadata which can
include:

- exec time
- metadata about the runtime host such as its CPU, memory, IPs, etc
- metadata about the cloud provider for the runner such as AWS account, region,
  ECS service, etc
- liveliness heartbeat

Chalk collects metadata in both cases and aggregating all that metadata can
then be used to connect the dots in interesting ways. For example it becomes
possible to reason about:

- what repos are deployed into production cloud environments?
- what repos are deployed into production which have a specific dependency via SBOM?
- how long does it take to deploy images to prod after they are built?
- what are the registries where base images are pulled from across the org?
- are the containers running successfully in prod via heartbeats?
- which version of the application is deployed in prod?
- etc

Now lets see how exactly chalk can collect all that metadata in order to help
connecting the dots in order to generate these valuable insights.

## Building

### Installing

Chalk is normally installed in the CI/CD pipeline. For GitHub actions
[setup-chalk-action](https://github.com/crashappsec/setup-chalk-action) can be
used which is as simple as adding the following step to the workflow file:

```yaml
- name: Set up Chalk
  uses: crashappsec/setup-chalk-action@main
```

This simple-to-use step does a couple of things behind the scenes:

- Downloads and installs `chalk` binary on the runner
- If attestation key is provided, configures `cosign` for `chalk` to sign built
  images.
- Wraps `docker` binary with `chalk`. After that point any invocation of
  `docker` will actually invoke `chalk` instead.

If for example later on GitHub workflow uses
[docker push action](https://github.com/docker/build-push-action):

```yaml
- name: Build and push
  uses: docker/build-push-action@v6
  with:
    context: mycontext
    file: Dockerfile.myapp
    push: true
    tags: myork/myapp:latest
```

Internally it will call `docker` similar to:

```bash
docker buildx build \
	--iidfile /home/runner/work/_temp/build-iidfile-d5ae58d5f2.txt \
	--metadata-file /home/runner/work/_temp/build-metadata-22f76f0b66.json \
	--tag myorg/myapp:latest \
	--push \
	-f Dockerfile.myapp \
	mycontext
```

### Wrapping

As `docker` is wrapped by `chalk`, it will allow `chalk` to intercept `docker`
invocations. `chalk` then parses `docker` CLI arguments to understand what is
being `built` which will include:

- whether `buildkit`, `buildx` or other Docker features are being used
- parse `Dockerfile.myapp` to:
  - parse all `Dockerfile` sections (for multi-stage builds)
  - parse all base images for all build stages
  - determine `ENTRYPOINT`/`CMD` for the image
- look for `git` repository in `mycontext` to lookup:
  - `git` remote URI
  - metadata about commit
    - id
    - author
    - signing information

Using the collected information above, `chalk` then creates a chalk mark file
(`chalk.json`) to be inserted into the image at `/chalk.json`.

If the original `Dockerfile.myapp` was:

```docker
FROM alpine
COPY myapp /myapp
```

`chalk` will adjust it by:

- pinning base images to specific digest for more deterministic builds
- add useful image `LABEL`s. By default `chalk` adds some metadata about the
  repo and the commit
- copy `chalk.json` to `/chalk.json`

```docker
# {{{ pinned to specific digest by chalk - https://crashoverride.com/docs/chalk
# FROM alpine
FROM alpine@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
# }}}

COPY myapp /myapp

# {{{ added by chalk - https://crashoverride.com/docs/chalk
LABEL run.crashoverride.origin-uri="git@github.com:crashappsec/chalk.git"
LABEL run.crashoverride.commit-id="8207bc68eb358dacb0c4334b760bfa3d5d4e3bc1"
COPY --chmod=0444 --from=chalkcontext chalk.json /chalk.json
# }}}
```

### Building

`chalk` will then adjust the original `docker` invocation to pass to it
modified `Dockerfile` via `stdin` (if possible) and will call actual `docker`
with it:

```bash
docker buildx build \
	--iidfile /home/runner/work/_temp/build-iidfile-d5ae58d5f2.txt \
	--metadata-file /home/runner/work/_temp/build-metadata-22f76f0b66.json \
	--tag myorg/myapp:latest \
	--push \
	-f - \ # adjusted by chalk
	mycontext \
	--build-context=chalkcontext=/tmp/chalktmp # added by chalk
```

`docker` can then build image as normal as if `chalk` was never there. This
allows `chalk` to transparently wrap any builds including:

- multi-stage builds
- multi-platform builds

### Inspecting

After the build is complete, `chalk` will inspect the built (and possibly
pushed) image and collect metadata about it:

- image id (image config digest)
- digests
- registries it was pushed to

### Signing

If `cosign` is enabled and the image was pushed to a registry, `chalk` will use
`cosign` to sign built image which will push its attestation to the registry.
See [Attestation](./attestation.md) for more details.

### Reporting

As the `build` is complete now, `chalk` will report all the collect metadata to
all configured sinks.

### Fallback

One of the core-principles of `chalk` is to never fail a build due to `chalk`
wrapping. As such, whenever a wrapped build fails, `chalk` will fallback to the
original `docker` build invocation, bypassing `chalk` altogether. This ensures
minimal impact to existing CI/CD pipelines when introducing `chalk` in them.

## Deploying

The luxury in CI/CD system is that `chalk` is able to wrap `docker` hence it is
able to wrap builds by intercepting `docker` invocations. Built docker images
can however be executed/deployed anywhere. That could be executed directly via
docker CLI or it can be used in cloud managed services such as AWS ECS. In
cloud environments, as the runtime is proprietary, `chalk` is unable to wrap
`docker` in order to detect when what images are executed. Therefore runtime
detection has to be built into the image itself.

### Entrypoint

To wrap image runtime, `chalk` wraps its `ENTRYPOINT`. Consider a `Dockerfile`:

```docker
FROM alpine
COPY myapp /myapp
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/myapp"]
```

In order to wrap its runtime, `ENTRYPOINT` can be adjusted to:

```docker
COPY --chmod=0755 --from=chalkcontext chalk /chalk
ENTRYPOINT ["/chalk", "exec", "--exec-command-name", "/docker-entrypoint.sh", "--"]
CMD ["/myapp"]
```

`chalk` prepends itself to existing `ENTRYPOINT` which allows `chalk` to be
executed whenever the built image is executed anywhere. In order to ensure
application logic is not changed, when `chalk exec` runs, it will:

- `exec` original `ENTRYPOINT` so pid 1 will always remain the original
  entrypoint
- `chalk` will fork itself to do runtime metadata collection/reporting.
  This includes:
  - Reading chalk mark embedded in the image at `/chalk.json`
  - Collecting metadata about cloud environments. In AWS for example its done
    via AWS metadata endpoints:
    - [EC2 Instance Metadata](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)
    - [ECS Cloud Metadata](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-metadata.html)
    - [Lambda environment variables](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html#configuration-envvars-runtime)

In shell pseudo-code here is roughly how `chalk` wraps `ENTRYPOINT`:

```bash
#!/bin/sh
/chalk report & < /chalk.json  # report metadata in background
shift                          # remove chalk-specific args
exec $@                        # original application should be pid 1
```

### Heartbeats

Normally in wrapped `ENTRYPOINT`, forked chalk reporting process exits
immediately on completion. When heartbeats are enabled, the reporting process,
instead of exiting, flushes most of the reporting state to reduce memory impact
and then sends periodic report (default every 10 minutes). The heartbeat report
by itself is as small as possible. Its primary purpose is to help identify
actively running services within the interval frequency.
