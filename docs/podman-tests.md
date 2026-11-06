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
Once Chalk attempts the instrumented build launch, Podman and Docker never
replay the original build. Injected failures can therefore leave the single
attempt unsuccessful, including the current shell guard in scratch images.
