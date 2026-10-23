#!/usr/bin/env python3
import errno
import os
from pathlib import Path
import pty
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]

PROBE_SOURCE = r'''
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "podman/run.h"

static void ignore_signal(int sig)
{
  struct sigaction action;

  memset(&action, 0, sizeof action);
  action.sa_handler = SIG_IGN;
  sigemptyset(&action.sa_mask);
  if (sigaction(sig, &action, NULL) != 0) {
    _exit(70);
  }
}

static int read_barrier(int fd)
{
  char byte;
  ssize_t count;

  do {
    count = read(fd, &byte, 1);
  } while (count < 0 && errno == EINTR);
  return count == 1 ? 0 : -1;
}

static int run_tty(const char *self, const char *scenario, int barrier,
                   pid_t controller_pgrp)
{
  chalk_podman_child_t result;
  char *child_stop[] = {(char *)self, "child-stop", NULL};
  char *child_background[] = {(char *)self, "child-background", NULL};
  char **child = strcmp(scenario, "initial-background") == 0
                   ? child_background : child_stop;
  pid_t expected_pgrp = strcmp(scenario, "foreground") == 0
                          ? getpgrp() : controller_pgrp;
  int ok;

  ignore_signal(SIGTTOU);
  ignore_signal(SIGTTIN);
  if (read_barrier(barrier) != 0) {
    return 71;
  }
  close(barrier);
  if (chalk_podman_run_attached(self, child, 0, &result) != 0) {
    return 72;
  }
  ok = result.kind == CHALK_PODMAN_EXITED && result.exit_code == 23 &&
       tcgetpgrp(STDIN_FILENO) == expected_pgrp;
  dprintf(STDERR_FILENO,
          "%s kind=%d exit=%d foreground=%d expected=%d\n", scenario,
          result.kind, result.exit_code, (int)tcgetpgrp(STDIN_FILENO),
          (int)expected_pgrp);
  chalk_podman_child_free(&result);
  return ok ? 0 : 73;
}

int main(int argc, char **argv)
{
  if (argc == 2 && strcmp(argv[1], "child-stop") == 0) {
    raise(SIGTSTP);
    return 23;
  }
  if (argc == 2 && strcmp(argv[1], "child-background") == 0) {
    return tcgetpgrp(STDIN_FILENO) == getpgrp() ? 74 : 23;
  }
  if (argc == 3 && strcmp(argv[1], "child-stop-file") == 0) {
    FILE *stream = fopen(argv[2], "w");
    if (stream == NULL) {
      return 75;
    }
    fprintf(stream, "%d\n", (int)getpid());
    if (fclose(stream) != 0) {
      return 76;
    }
    raise(SIGSTOP);
    return 23;
  }
  if (argc == 3 && strcmp(argv[1], "child-wait-file") == 0) {
    FILE *stream = fopen(argv[2], "w");
    if (stream == NULL) {
      return 80;
    }
    fprintf(stream, "%d\n", (int)getpid());
    if (fclose(stream) != 0) {
      return 81;
    }
    for (;;) {
      pause();
    }
  }
  if (argc == 5 && strcmp(argv[1], "runner-tty") == 0) {
    return run_tty(argv[0], argv[2], atoi(argv[3]), (pid_t)atoi(argv[4]));
  }
  if (argc == 3 && strcmp(argv[1], "runner-no-tty") == 0) {
    chalk_podman_child_t result;
    char *child[] = {argv[0], "child-stop-file", argv[2], NULL};
    int ok;
    if (chalk_podman_run_attached(argv[0], child, 0, &result) != 0) {
      return 77;
    }
    ok = result.kind == CHALK_PODMAN_EXITED && result.exit_code == 23;
    chalk_podman_child_free(&result);
    return ok ? 0 : 78;
  }
  if (argc == 4 && strcmp(argv[1], "runner-cancel") == 0) {
    chalk_podman_child_t result;
    char *child[] = {argv[0], "child-wait-file", argv[2], NULL};
    int expected = atoi(argv[3]);
    int exit_code;
    if (chalk_podman_run_attached(argv[0], child, 0, &result) != 0) {
      return 82;
    }
    exit_code = result.forwarded == expected ? 128 + result.forwarded : 83;
    chalk_podman_child_free(&result);
    return exit_code;
  }
  return 79;
}
'''


def wait_for_state(pid, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WUNTRACED | os.WNOHANG)
        if waited == pid:
            return status
        time.sleep(0.01)
    raise TimeoutError(f"process {pid} did not change state")


class TestPodmanRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="chalk-podman-run-")
        cls.probe = Path(cls.temp.name) / "probe"
        source = Path(cls.temp.name) / "probe.c"
        source.write_text(PROBE_SOURCE)
        subprocess.run([
            os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
            "-Werror", "-I", str(ROOT / "src"), str(source),
            str(ROOT / "src/podman/run.c"), "-o", str(cls.probe),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_tty_scenario(self, scenario):
        controller, master = pty.fork()
        if controller == 0:
            runner = None
            exit_code = 2
            try:
                signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                signal.signal(signal.SIGTTIN, signal.SIG_IGN)
                controller_pgrp = os.getpgrp()
                read_fd, write_fd = os.pipe()
                os.set_inheritable(read_fd, True)
                runner = os.fork()
                if runner == 0:
                    os.close(write_fd)
                    os.setpgid(0, 0)
                    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
                    signal.signal(signal.SIGTTIN, signal.SIG_DFL)
                    os.execv(self.probe, [str(self.probe), "runner-tty", scenario,
                                           str(read_fd), str(controller_pgrp)])
                os.close(read_fd)
                os.setpgid(runner, runner)
                if scenario != "initial-background":
                    os.tcsetpgrp(0, runner)
                os.write(write_fd, b"x")
                os.close(write_fd)

                if scenario == "initial-background":
                    status = wait_for_state(runner, 3)
                    valid = os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
                    valid = valid and os.tcgetpgrp(0) == controller_pgrp
                else:
                    status = wait_for_state(runner, 3)
                    valid = os.WIFSTOPPED(status) and os.WSTOPSIG(status) == signal.SIGSTOP
                    os.tcsetpgrp(0, controller_pgrp)
                    if scenario == "foreground":
                        os.tcsetpgrp(0, runner)
                    os.kill(runner, signal.SIGCONT)
                    status = wait_for_state(runner, 3)
                    valid = valid and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
                    expected = runner if scenario == "foreground" else controller_pgrp
                    valid = valid and os.tcgetpgrp(0) == expected
                os.tcsetpgrp(0, controller_pgrp)
                exit_code = 0 if valid else 1
            except BaseException:
                exit_code = 2
            finally:
                if runner:
                    try:
                        os.killpg(runner, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            os._exit(exit_code)

        try:
            status = wait_for_state(controller, 6)
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            self.assertTrue(os.WIFEXITED(status), output.decode(errors="replace"))
            self.assertEqual(os.WEXITSTATUS(status), 0, output.decode(errors="replace"))
        finally:
            os.close(master)
            try:
                os.kill(controller, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_foreground_stop_and_resume(self):
        self.run_tty_scenario("foreground")

    def test_background_resume_does_not_take_terminal(self):
        self.run_tty_scenario("background-resume")

    def test_initial_background_run_does_not_take_terminal(self):
        self.run_tty_scenario("initial-background")

    def test_no_tty_does_not_mirror_child_stop(self):
        with tempfile.TemporaryDirectory(prefix="chalk-podman-stop-") as temp:
            pidfile = Path(temp) / "child.pid"
            process = subprocess.Popen(
                [str(self.probe), "runner-no-tty", str(pidfile)],
                stdin=subprocess.DEVNULL,
            )
            child = None
            mirrored_stop = False
            try:
                deadline = time.monotonic() + 3
                while not pidfile.exists():
                    self.assertIsNone(process.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                child = int(pidfile.read_text())

                deadline = time.monotonic() + 0.5
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                    if waited == process.pid:
                        mirrored_stop = os.WIFSTOPPED(status)
                        break
                    time.sleep(0.01)
                os.kill(child, signal.SIGCONT)
                if mirrored_stop:
                    os.kill(process.pid, signal.SIGCONT)
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertFalse(mirrored_stop, "wrapper mirrored a child stop without a tty")
            finally:
                for pid in (child, process.pid):
                    if pid:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_forwarded_cancellation_controls_exit(self):
        for sent_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sent_signal.name), \
                 tempfile.TemporaryDirectory(prefix="chalk-podman-cancel-") as temp:
                pidfile = Path(temp) / "child.pid"
                process = subprocess.Popen(
                    [str(self.probe), "runner-cancel", str(pidfile), str(sent_signal)],
                    stdin=subprocess.DEVNULL,
                )
                child = None
                try:
                    deadline = time.monotonic() + 3
                    while not pidfile.exists():
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    child = int(pidfile.read_text())
                    process.send_signal(sent_signal)
                    self.assertEqual(process.wait(timeout=3), 128 + sent_signal)
                finally:
                    for pid in (child, process.pid):
                        if pid:
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass


if __name__ == "__main__":
    unittest.main()
