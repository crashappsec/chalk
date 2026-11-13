# Run the Podman product checks

Run the Nim unit suite through `make unit-tests`. Use `DOCKER=` to run on a host
with the documented Chalk dependencies. The suite includes Podman command
routing, startup configuration, immutable image binding, platform selection,
process handling, quiet output, confidential-value redaction, and collection
of customer-generated SPDX documents.

Run `python3 tests/unit/test_podman_run.py` explicitly. The Nim test task does not
execute Python process tests. These tests compile the C process adapter and
exercise inherited signal handling and cancellation without an engine.

On a Linux host with local Podman, run each applicable integration script with
the candidate path, for example
`python3 tests/integration/test_podman_build.py ./chalk`. The `test_podman_*.py`
scripts accept this argument except `test_podman_platform_proof.py`, which is a
standalone Python unit test. Run that test with
`python3 tests/integration/test_podman_platform_proof.py`.

Engine integration tests require compatible native engine capabilities. The
platform integration cases exercise an amd64 builder and ARM emulation and do
not establish native arm64 support. Registry cases require a registry. Engine
checks and registry checks are independent of backend report acceptance. A
successful pre-launch native fallback does not establish successful instrumentation.
Once Chalk attempts an instrumented Podman launch, it never replays the
original build. Preparation errors may run the original command once.
Docker retains its established fallback: a failed rewritten build or a
non-policy wrapping exception runs the original command. Policy refusal never
starts a fallback. Test these contracts separately.

The `unit-tests` workflow automatically runs the Nim suite, the Python process
and platform checks, the Docker fallback diagnostic, and the Podman controls
and heredoc command checks. The `podman-contracts` workflow builds the candidate
and runs native build, authenticated registry, and capability checks on
AMD64 and ARM64 with pinned Podman 6.1.4 and Buildah 1.45.2. These checks do not
establish connected backend delivery.

## Configure Podman wrapping

Set `podman.wrap_entrypoint = false` in a Chalk configuration file to run the
original Podman build without a mark, copied Chalk binary, ONBUILD hook, or
startup rewrite. The default is `true`, independent of Docker wrapping
configuration. Unsupported virtual Podman commands exit with usage status 2
before invoking the engine.

## Verify engine capabilities

On a disposable local Linux Podman fixture, run:

```sh
python3 tests/integration/podman_compatibility_probe.py --expect-podman 6.1.4 --expect-buildah 1.45.2
```
The probe builds temporary images and checks named contexts, exec-form RUN
mounts from a context, COPY permissions, and inherited ONBUILD execution.
It removes its images after the check.

Instrumentation accepts the following exact Podman and Buildah pairs, measured
on both native architectures. Other pairs receive one unchanged native build.
The measurements establish no general minimum version.

| Podman | Buildah |
| --- | --- |
| 4.9.4 | 1.33.7 |
| 5.0.3 | 1.35.4 |
| 5.2.5 | 1.37.5 |
| 5.4.2 | 1.39.4 |
| 5.6.2 | 1.41.5 |
| 6.1.4 | 1.45.2 |

The [native capability measurement pipeline](https://gitlab.com/crashappsec/chalk-orchestration/-/pipelines/3066209923)
retains the 12 fixture receipts. Access requires repository permission.
