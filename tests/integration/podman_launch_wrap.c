/* Link only into the diagnostic binary with --wrap=chalk_podman_run_attached. */
#include "podman/run.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int __real_chalk_podman_run_attached(const char *, char *const [], int,
                                    chalk_podman_child_t *);

int __wrap_chalk_podman_run_attached(const char *exe, char *const argv[],
                                    int capture, chalk_podman_child_t *out)
{
    const char *ledger = getenv("STAGE_LAUNCH_LEDGER");
    const char *fault = getenv("STAGE_LAUNCH_FAULT");
    int injected = 0;
    for (int i = 0; argv[i]; ++i) {
        if (strcmp(argv[i], "--build-context") == 0) injected = 1;
    }
    if (ledger && argv[1] && strcmp(argv[1], "build") == 0) {
        FILE *stream = fopen(ledger, "a");
        if (!stream) abort();
        fprintf(stream, "%s\n", injected ? "injected" : argv[1]);
        fclose(stream);
    }
    if (injected && fault && strcmp(fault, "spawn") == 0) {
        return __real_chalk_podman_run_attached(
            "/nonexistent-stage01-engine", argv, capture, out);
    }
    int result = __real_chalk_podman_run_attached(exe, argv, capture, out);
    if (injected && fault && strcmp(fault, "unknown") == 0) {
        out->kind = CHALK_PODMAN_SPAWNFAILED;
        out->exit_code = 127;
    }
    return result;
}
