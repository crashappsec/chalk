/*
 * Copyright (c) 2026, Crash Override, Inc.
 *
 * This file is part of Chalk
 * (see https://crashoverride.com/docs/chalk)
 */

#define _POSIX_C_SOURCE 200809L
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "run.h"

static volatile sig_atomic_t g_forwarded;
static const int g_preserved_signals[] = {
  SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGFPE, SIGBUS, SIGSEGV,
  SIGPIPE, SIGTERM, SIGTTOU, SIGTTIN
};
static struct sigaction g_original_actions[
  sizeof g_preserved_signals / sizeof g_preserved_signals[0]
];
static sigset_t g_original_mask;
static int g_original_state_ready;

enum {
  CHALK_PODMAN_CANCEL_GRACE_MS = 20000,
  CHALK_PODMAN_POLL_MS = 10
};

static void chalk_podman_handler(int sig)
{
  g_forwarded = sig;
}

int chalk_podman_snapshot_process_state(void)
{
  size_t i;

  if (g_original_state_ready) {
    return 0;
  }
  if (sigprocmask(SIG_SETMASK, NULL, &g_original_mask) != 0) {
    return -1;
  }
  for (i = 0;
       i < sizeof g_preserved_signals / sizeof g_preserved_signals[0];
       i++) {
    if (sigaction(g_preserved_signals[i], NULL, &g_original_actions[i]) != 0) {
      return -1;
    }
  }
  g_original_state_ready = 1;
  return 0;
}

__attribute__((constructor))
static void chalk_podman_snapshot_constructor(void)
{
  (void)chalk_podman_snapshot_process_state();
}

static void restore_original_process_state(void)
{
  size_t i;

  if (!g_original_state_ready) {
    return;
  }
  for (i = 0;
       i < sizeof g_preserved_signals / sizeof g_preserved_signals[0];
       i++) {
    sigaction(g_preserved_signals[i], &g_original_actions[i], NULL);
  }
  sigprocmask(SIG_SETMASK, &g_original_mask, NULL);
}

int chalk_podman_exec_replacing_self(const char *exe, char *const argv[])
{
  restore_original_process_state();
  execv(exe, argv);
  return -1;
}

void chalk_podman_child_free(chalk_podman_child_t *child)
{
  if (child == NULL) {
    return;
  }
  free(child->stdout_bytes);
  free(child->stderr_bytes);
  child->stdout_bytes = NULL;
  child->stderr_bytes = NULL;
}

static int set_cloexec(int fd)
{
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) {
    return -1;
  }
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblocking(int fd)
{
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) {
    return -1;
  }
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int append_fd(int fd, char **buf, size_t *len)
{
  char tmp[4096];
  ssize_t n;

  for (;;) {
    n = read(fd, tmp, sizeof tmp);
    if (n > 0) {
      char *next = realloc(*buf, *len + (size_t)n + 1);
      if (next == NULL) {
        return -1;
      }
      memcpy(next + *len, tmp, (size_t)n);
      *len += (size_t)n;
      next[*len] = '\0';
      *buf = next;
      continue;
    }
    if (n == 0) {
      return 0;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      return 0;
    }
    return -1;
  }
}

static void kill_owned(pid_t pid, pid_t pgid, int sig)
{
  if (pgid > 0) {
    kill(-pgid, sig);
  }
  if (pid > 0) {
    kill(pid, sig);
  }
}

static long elapsed_ms(const struct timespec *start)
{
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (now.tv_sec - start->tv_sec) * 1000L +
         (now.tv_nsec - start->tv_nsec) / 1000000L;
}

static int terminal_foreground_is(pid_t pgrp)
{
  return pgrp > 0 && tcgetpgrp(STDIN_FILENO) == pgrp;
}

int chalk_podman_run_attached(const char *exe, char *const argv[], int capture,
                              chalk_podman_child_t *out)
{
  int errpipe[2] = {-1, -1};
  int outpipe[2] = {-1, -1};
  int errcap[2] = {-1, -1};
  pid_t pid;
  pid_t pgid;
  pid_t oldpgrp = -1;
  int have_tty = 0;
  int status = 0;
  int sent_kill = 0;
  int waiting_cancel = 0;
  struct timespec cancel_start;
  struct sigaction act, oldact[4];
  const int sigs[4] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
  sigset_t block, oldmask, waitmask;
  size_t out_len = 0;
  size_t err_len = 0;
  int i;

  memset(out, 0, sizeof *out);
  out->kind = CHALK_PODMAN_SPAWNFAILED;
  out->exit_code = 127;
  g_forwarded = 0;

  if (pipe(errpipe) != 0) {
    return -1;
  }
  if (set_cloexec(errpipe[0]) != 0 || set_cloexec(errpipe[1]) != 0 ||
      set_nonblocking(errpipe[0]) != 0) {
    close(errpipe[0]);
    close(errpipe[1]);
    return -1;
  }
  if (capture) {
    if (pipe(outpipe) != 0 || pipe(errcap) != 0) {
      close(errpipe[0]);
      close(errpipe[1]);
      if (outpipe[0] >= 0) {
        close(outpipe[0]);
        close(outpipe[1]);
      }
      return -1;
    }
  }

  sigemptyset(&block);
  for (i = 0; i < 4; i++) {
    sigaddset(&block, sigs[i]);
  }
  sigprocmask(SIG_BLOCK, &block, &oldmask);

  pid = fork();
  if (pid < 0) {
    sigprocmask(SIG_SETMASK, &oldmask, NULL);
    close(errpipe[0]);
    close(errpipe[1]);
    if (capture) {
      close(outpipe[0]);
      close(outpipe[1]);
      close(errcap[0]);
      close(errcap[1]);
    }
    return -1;
  }

  if (pid == 0) {
    int nullfd;
    setpgid(0, 0);
    restore_original_process_state();
    close(errpipe[0]);
    if (capture) {
      nullfd = open("/dev/null", O_RDONLY);
      if (nullfd >= 0) {
        dup2(nullfd, STDIN_FILENO);
        close(nullfd);
      }
      dup2(outpipe[1], STDOUT_FILENO);
      dup2(errcap[1], STDERR_FILENO);
      close(outpipe[0]);
      close(outpipe[1]);
      close(errcap[0]);
      close(errcap[1]);
    }
    execv(exe, argv);
    {
      int saved = errno;
      write(errpipe[1], &saved, sizeof saved);
    }
    _exit(127);
  }

  setpgid(pid, pid);
  pgid = pid;
  close(errpipe[1]);
  if (capture) {
    close(outpipe[1]);
    close(errcap[1]);
    fcntl(outpipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errcap[0], F_SETFL, O_NONBLOCK);
  }

  memset(&act, 0, sizeof act);
  act.sa_handler = chalk_podman_handler;
  sigemptyset(&act.sa_mask);
  for (i = 0; i < 4; i++) {
    sigaddset(&act.sa_mask, sigs[i]);
  }
  for (i = 0; i < 4; i++) {
    sigaction(sigs[i], &act, &oldact[i]);
  }

  have_tty = !capture && isatty(STDIN_FILENO);
  if (have_tty) {
    oldpgrp = tcgetpgrp(STDIN_FILENO);
    if (oldpgrp == getpgrp()) {
      tcsetpgrp(STDIN_FILENO, pid);
    }
  }

  waitmask = oldmask;
  for (i = 0; i < 4; i++) {
    sigdelset(&waitmask, sigs[i]);
  }
  sigprocmask(SIG_SETMASK, &waitmask, NULL);

  for (;;) {
    pid_t waited;
    int execerr = 0;
    ssize_t n;
    int flags;

    if (g_forwarded && !waiting_cancel) {
      waiting_cancel = 1;
      clock_gettime(CLOCK_MONOTONIC, &cancel_start);
      kill_owned(pid, pgid, (int)g_forwarded);
    }
    flags = WNOHANG | WUNTRACED;
#ifdef WCONTINUED
    flags |= WCONTINUED;
#endif

    n = read(errpipe[0], &execerr, sizeof execerr);
    if (n == (ssize_t)sizeof execerr) {
      while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
      }
      out->kind = CHALK_PODMAN_SPAWNFAILED;
      out->exit_code = 127;
      break;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }

    if (capture) {
      append_fd(outpipe[0], &out->stdout_bytes, &out_len);
      append_fd(errcap[0], &out->stderr_bytes, &err_len);
    }

    waited = waitpid(pid, &status, flags);
    if (waited == pid) {
      if (WIFSTOPPED(status)) {
        if (!have_tty) {
          continue;
        }
        if (oldpgrp > 0 && terminal_foreground_is(pgid)) {
          tcsetpgrp(STDIN_FILENO, oldpgrp);
        }
        raise(SIGSTOP);
        if (terminal_foreground_is(getpgrp())) {
          tcsetpgrp(STDIN_FILENO, pgid);
        }
        if (pgid > 0) {
          kill(-pgid, SIGCONT);
        } else {
          kill(pid, SIGCONT);
        }
        continue;
      }
#ifdef WIFCONTINUED
      if (WIFCONTINUED(status)) {
        continue;
      }
#endif
      if (WIFEXITED(status)) {
        out->kind = CHALK_PODMAN_EXITED;
        out->exit_code = WEXITSTATUS(status);
      } else if (WIFSIGNALED(status)) {
        out->kind = CHALK_PODMAN_SIGNALED;
        out->sig = WTERMSIG(status);
      } else {
        continue;
      }
      if (waiting_cancel) {
        kill_owned(pid, pgid, SIGKILL);
      }
      break;
    }
    if (waited < 0 && errno == EINTR) {
      continue;
    }
    if (waited == 0) {
      if (waiting_cancel && !sent_kill &&
          elapsed_ms(&cancel_start) >= CHALK_PODMAN_CANCEL_GRACE_MS) {
        kill_owned(pid, pgid, SIGKILL);
        sent_kill = 1;
      }
      {
        struct timespec pause_ts;
        pause_ts.tv_sec = 0;
        pause_ts.tv_nsec = CHALK_PODMAN_POLL_MS * 1000 * 1000;
        nanosleep(&pause_ts, NULL);
      }
      continue;
    }
    out->kind = CHALK_PODMAN_SPAWNFAILED;
    out->exit_code = 127;
    break;
  }

  out->forwarded = (int)g_forwarded;
  if (capture) {
    append_fd(outpipe[0], &out->stdout_bytes, &out_len);
    append_fd(errcap[0], &out->stderr_bytes, &err_len);
    close(outpipe[0]);
    close(errcap[0]);
  }
  close(errpipe[0]);

  if (have_tty && oldpgrp > 0 &&
      (terminal_foreground_is(pgid) || terminal_foreground_is(getpgrp()))) {
    tcsetpgrp(STDIN_FILENO, oldpgrp);
  }
  for (i = 0; i < 4; i++) {
    sigaction(sigs[i], &oldact[i], NULL);
  }
  sigprocmask(SIG_SETMASK, &oldmask, NULL);
  return 0;
}
