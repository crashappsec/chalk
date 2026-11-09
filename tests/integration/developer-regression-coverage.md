# Developer regression coverage

The GitHub developer suite runs process-adapter diagnostics, direct signing-provider checks, and simulated consumer selection. The GitLab customer rig downloads production Chalk and compares native and instrumented workloads. Diagnostic executables stay inside GitHub test jobs. Job artifacts contain JSON reports and the text AppArmor profile; they exclude executables.

<!-- markdown-link-check-disable -->

This inventory reconciles every assertion from [GitLab pipeline 3039465500](https://gitlab.com/crashappsec/chalk-orchestration/-/pipelines/3039465500) at rig revision `f6bf4a64fdc79353e5d6952460068190402d3ca7`. That pipeline used `SOURCE_SHA=db3073bc3eedd67c77e7738fc1a53ea671e498f6`, `RIG_PASS=stage06`, and `TRIAL_MODE=merged`. The job commands explicitly selected `candidate` for the earlier stages. The final `stage06.py` inherited `merged`. Both values select the non-baseline expectations.

[The assertion inventory](developer-regression-coverage.tsv) identifies each original file, source line, predicate, job, disposition, and destination. GitHub paths belong to this repository. GitLab paths belong to [the customer rig repository](https://gitlab.com/crashappsec/chalk-orchestration). Destination paths omit line numbers because formatting can move a predicate without changing it. The frozen original predicate remains in each row.

<!-- markdown-link-check-enable -->

## Assertions and destinations

The inventory has 248 rows, including all 218 explicit Python assertions in the six stage scripts, diagnostic Nim assertions, validation calls, and build-script checks. Fifteen rows were not reached by the frozen pipeline. The remaining rows have a GitHub destination, a GitLab destination, or both.

| Disposition  | Rows | Meaning                                                                                                               |
| ------------ | ---- | --------------------------------------------------------------------------------------------------------------------- |
| Retained     | 120  | The customer predicate remains in GitLab against production bytes.                                                    |
| Moved        | 42   | The developer predicate runs in GitHub.                                                                               |
| Repeated     | 26   | GitHub repeats the original build-outcome test while GitLab independently checks observable status and nonce effects. |
| Replaced     | 45   | The row explains the new architecture, acquisition, installation, or workload predicate.                              |
| Not executed | 15   | The frozen pipeline did not enter this baseline or skipped path.                                                      |

`test_build_outcomes.py` preserves the original candidate build outcomes for real Docker and Podman. It includes warm-cache failures, injected pre-launch failures, preparation fallback, reserved-path refusal, reporting failure, forced Docker terminal outcomes, and the original cancellation shim. Its unknown-outcome test still runs real Podman 6.1.4 and requires one nonce-bearing HTTP effect after the diagnostic adapter reports an unknown outcome. Evidence retains engine calls, statuses, reports, HTTP events, and cleanup. GitLab uses real-process cancellation without a behavior-changing engine shim.

`test_signing_provider.py` retains valid signatures and password retrieval, malformed responses, missing fields, HTTP failures, response-redaction assertions, and numeric status at info and trace levels. The helper is compiled inside the job. GitLab no longer downloads a signing-helper archive.

`test_simulated_selector.py` retains disabled selection, project scoping, checksum rejection, environment scrubbing, setup failure, and installed selection. Its vendored selector and installer come from the frozen rig revision. Real installation, identical reinstall, replacement refusal, rollback, and customer application comparisons run in GitLab with production downloads. The earlier GitLab-built rollback archive is retired.

The developer script also runs the original Podman unit files, Python process probe, and input-notice test. The full unit suite remains a separate manual selection.

## Native versions and replacements

Manual fast functional jobs and manual full-unit or developer jobs pin Docker 29.2.1. The fast functional image uses that Docker client, Buildx 0.38.1, and an architecture-specific test cache. Automatic workflow behavior retains its existing runner, selection, and defaults.

The developer job installs checksum-pinned Podman 6.1.4 archives for x86-64 or ARM64 and verifies rootless operation and Buildah 1.45.2 through `podman info`. Customer jobs use independently proven native fixtures. Both locations generalize ELF, reported CPU, and Linux checks to the executing architecture.

GitLab's source-build input gates are replaced by committed two-architecture manifests and acquisition checks for source, checksum, ELF architecture, build CPU, and Linux OS. Missing inputs or failed acquisition cannot select another candidate or trigger a local Chalk build. GitHub's in-job identity record retains the source, dependency revisions, and helper checksums without publishing executables.

The application working-directory comparison now uses `/application` and checks the directory reported by the process. Podman retains scratch, shell-free, non-root, collision, lineage, descendant identity, publication, and extraction checks. Docker adds the complete application comparison through both handled signals. A successful fallback does not satisfy positive instrumentation checks.

## Evidence limits

The mapping describes inspected test placement. Native GitHub workflow results and GitLab acceptance evidence establish execution. A syntax check or inventory row does not establish that its predicate passed.

The stage06 pipeline did not invoke `stage03-mount.py`, `stage04-check.py`, or `stage04-format.py`. Those optional historical paths are outside this cohort. The customer pipeline cannot select source compilation or diagnostic-download paths.
