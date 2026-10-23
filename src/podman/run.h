/*
 * Copyright (c) 2026, Crash Override, Inc.
 *
 * This file is part of Chalk
 * (see https://crashoverride.com/docs/chalk)
 */

#ifndef CHALK_PODMAN_RUN_H
#define CHALK_PODMAN_RUN_H

enum {
  CHALK_PODMAN_EXITED = 0,
  CHALK_PODMAN_SIGNALED = 1,
  CHALK_PODMAN_SPAWNFAILED = 2
};

typedef struct {
  int kind;
  int exit_code;
  int sig;
  int forwarded;
  char *stdout_bytes;
  char *stderr_bytes;
} chalk_podman_child_t;

int chalk_podman_snapshot_process_state(void);
int chalk_podman_exec_replacing_self(const char *exe, char *const argv[]);
int chalk_podman_run_attached(const char *exe, char *const argv[], int capture,
                              chalk_podman_child_t *out);
void chalk_podman_child_free(chalk_podman_child_t *child);

#endif
