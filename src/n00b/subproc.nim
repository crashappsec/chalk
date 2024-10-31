import std/[
  posix,
]
import ".."/[
  utils/times,
]
import "."/[
  types,
  wrapping/duration,
  wrapping/kwargs,
  wrapping/string,
]

export types

when defined(no_chalk):
  proc trace(s: string) =
    echo(s)
else:
  import pkg/[
    nimutils/logging,
  ]

proc n00b_run_process(
  cmd:     ptr n00b_string_t,
  argv:    ptr n00b_list_t,
  proxy:   bool,
  capture: bool,
  ka:      ptr n00b_karg_info_t,
): ptr n00b_proc_t {.varargs,
                    header:"n00b/io.h",
                    importc:"_n00b_run_process"}

proc n00b_proc_run(p: ptr n00b_proc_t, timeout: ptr n00b_duration_t) {.header:"n00b/io.h".}

proc n00b_proc_capture_stdin(p: ptr n00b_proc_t) {.header:"n00b/io.h".}
proc n00b_proc_capture_stdout(p: ptr n00b_proc_t) {.header:"n00b/io.h".}
proc n00b_proc_capture_stderr(p: ptr n00b_proc_t) {.header:"n00b/io.h".}

proc n00b_proc_proxy_stdin(p: ptr n00b_proc_t) {.header:"n00b/io.h".}
proc n00b_proc_proxy_stdout(p: ptr n00b_proc_t) {.header:"n00b/io.h".}
proc n00b_proc_proxy_stderr(p: ptr n00b_proc_t) {.header:"n00b/io.h".}

proc n00b_proc_get_stdin_capture(p: ptr n00b_proc_t): ptr n00b_buf_t {.header:"n00b/io.h".}
proc n00b_proc_get_stdout_capture(p: ptr n00b_proc_t): ptr n00b_buf_t {.header:"n00b/io.h".}
proc n00b_proc_get_stderr_capture(p: ptr n00b_proc_t): ptr n00b_buf_t {.header:"n00b/io.h".}

proc n00b_proc_get_exit_code(p: ptr n00b_proc_t): cint {.header:"n00b/io.h".}

type
  CommandStd* = enum
    StdIn
    StdOut
    StdErr
    All

let isStdinTTY = isatty(0) != 0

proc exitCode*(p: ptr n00b_proc_t): int =
  result = int(n00b_proc_get_exit_code(p))
  when defined(debug):
    trace("exit_code: " & $result)

proc stdin*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stdin_capture(p))
  when defined(debug):
    trace("stdin: " & result)

proc stdout*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stdout_capture(p))
  when defined(debug):
    trace("stdout: " & result)

proc stderr*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stderr_capture(p))
  when defined(debug):
    trace("stderr: " & result)

proc runCommand*(
  cmd:     string,
  args:    seq[string],
  proxy:   set[CommandStd] = {},
  capture: set[CommandStd] = {All},
  stdin                    = "",
  merge                    = false,
  pty                      = false,
  verbose                  = false,
  timeout                  = initDuration(minutes = 1),
): ptr n00b_proc_t =
  ## Run external command as a subprocess
  ##
  ## args:
  ## cmd:
  ## args:
  ## proxy: which std* FDs to proxy to subprocess
  ## capture: which std* FDs to capture in subprocess
  ## stdin: additional stdin to pass to subproccess
  ## merge: merge stdout/stderr to stdout
  ## pty: run subprocess with pty.
  ##      automatically enabled when stdin is a TTY and it is proxied to subprocess.
  ## verbose: log cmd/args as trace logs
  ## timeout:

  var pty = pty
  # if parent stdin is a TTY and stdin is proxied to a child process
  # run it with PTY as the subcommand might require PTY to succeed
  # if isStdinTTY and (StdIn in proxy or All in proxy):
  #   pty = true

  when defined(debug):
    trace("cmd: "     & cmd)
    trace("args: "    & $args)
    trace("stdin: "   & stdin)
    trace("proxy: "   & $proxy   & " " & $(All in proxy))
    trace("capture: " & $capture & " " & $(All in capture))
    trace("merge: "   & $merge)
    trace("pty: "     & $pty)
    trace("timeout: " & $timeout)
  else:
    if verbose:
      trace(cmd & " " & args.join(" "))
      if stdin != "":
        trace("stdin:\n" & stdin)

  let n00bTimeout =
    if timeout > initDuration():
      @timeout
    else:
      cast[ptr n00b_duration_t](nil)

  result = n00b_run_process(
    @cmd,
    @args,
    All in proxy,
    All in capture,
    n00bKwargs(
      n00bKw("pty",             pty),
      n00bKw("merge",           merge),
      n00bKw("stdin_injection", @stdin),
      n00bKw("run",             false),
    ),
  )

  if StdIn in capture:
    result.n00b_proc_capture_stdin()
  if StdOut in capture:
    result.n00b_proc_capture_stdout()
  if StdErr in capture:
    result.n00b_proc_capture_stderr()
  if StdIn in proxy or stdin != "":
    result.n00b_proc_proxy_stdin()
  if StdOut in proxy:
    result.n00b_proc_proxy_stdout()
  if StdErr in proxy:
    result.n00b_proc_proxy_stderr()

  result.n00b_proc_run(n00bTimeout)

  when defined(debug):
    discard result.exitCode
    discard result.stdout
    discard result.stderr
  else:
    if result.exitCode > 0 and verbose:
      trace(strutils.strip(result.stderr & result.stdout))
