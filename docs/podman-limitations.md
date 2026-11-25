# Podman preparation limits

Podman instrumentation wraps selected local Linux builds. Unsupported invocations
run through the native engine. A successful native fallback can therefore
produce an image without a Chalk mark. Check the mark and application behavior
when assessing an instrumented build.

The implementation requires a local engine and compatible binary, command,
host, and image platforms. It refuses unresolved image identities and conflicting
platform declarations. Remote services cannot use the local workspace paths
that instrumentation supplies. The implementation does not detect an existing
image whose contents contradict its own platform metadata.

The command-line classifier supports an explicit set of build options. Other
options, unsupported Containerfile forms, unavailable startup configuration,
reserved image paths, and unsupported context arrangements can prevent
instrumentation. Chalk can run the original command if preparation fails.
If an instrumented build exits normally with a nonzero status, Chalk prints
the status to stderr, retries once with the original arguments, and returns
the native exit status. Both attempts write to the caller's stdout and stderr.
A build can run twice and repeat any side effects of its steps.

Cancellation, signal termination, timeouts, indeterminate launch or wait
outcomes, and post-build collection failures do not trigger a retry.

The reserved-path check runs before Chalk copies its files into the image.
A customer file at a reserved path can cause the instrumented attempt to fail.
The native retry uses the original recipe, so it can succeed and preserve
the customer file and startup configuration.

The oldest supported Podman and Buildah versions have not been established.
Version-specific successful comparisons establish observations for those
fixtures and commands. They do not establish a general version floor or full
support for those engine releases. A per-instruction network optimization uses
a conservative Buildah threshold independently of the general host gate.

This preparation does not add Podman build policy evaluation. Existing public
Docker policy behavior remains separate. Registry transfer, backend report
receipt and association, execution telemetry, and heartbeat validation require
separate end-to-end evidence. Installer behavior and stale interposition copies
remain outside this preparation.
