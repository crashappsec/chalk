import std/[
  posix,
  strutils,
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
  StdFD* = enum
    StdInFD
    StdOutFD
    StdErrFD
    StdAllFD

let isStdinTTY = isatty(0) != 0

proc exitCode*(p: ptr n00b_proc_t): int =
  result = int(n00b_proc_get_exit_code(p))

proc stdin*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stdin_capture(p))

proc stdout*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stdout_capture(p))

proc stderr*(p: ptr n00b_proc_t): string =
  result = $(n00b_proc_get_stderr_capture(p))

proc runCommand*(
  cmd:     string,
  args:    seq[string],
  proxy:   set[StdFD] = {},
  capture: set[StdFD] = {StdOutFD, StdErrFD},
  stdin               = "",
  merge               = false,
  pty                 = false,
  verbose             = false,
  timeout             = initDuration(minutes = 10),
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

  if cmd == "":
    raise newException(ValueError, "cannot run empty command name")

  var pty = pty
  # if parent stdin is a TTY and stdin is proxied to a child process
  # run it with PTY as the subcommand might require PTY to succeed
  # if isStdinTTY and (StdIn in proxy or All in proxy):
  #   pty = true

  when defined(debug):
    trace("cmd:         " & cmd)
    trace("args:        " & $args)
    trace("stdin:       " & stdin)
    trace("close_stdin: " & $(stdin != ""))
    trace("proxy:       " & $proxy   & " all=" & $(StdAllFD in proxy))
    trace("capture:     " & $capture & " all=" & $(StdAllFD in capture))
    trace("merge:       " & $merge)
    trace("pty:         " & $pty)
    trace("timeout:     " & $timeout)
  else:
    if verbose:
      trace(cmd & " " & args.join(" "))
      if stdin != "":
        trace("stdin:\n" & stdin)

  # TODO n00b
  let n00bTimeout = cast[ptr n00b_duration_t](nil)
    # if timeout > initDuration():
    #   @timeout
    # else:
    #   cast[ptr n00b_duration_t](nil)

  result = n00b_run_process(
    @cmd,
    @args,
    StdAllFD in proxy,
    StdAllFD in capture,
    n00bKwargs(
      n00bKw("pty",             pty),
      n00bKw("merge",           merge),
      n00bKw("stdin_injection", @stdin),
      n00bKw("close_stdin",     stdin != ""),
      n00bKw("run",             false),
    ),
  )

  if StdInFD in capture:
    result.n00b_proc_capture_stdin()
  if StdOutFD in capture:
    result.n00b_proc_capture_stdout()
  if StdErrFD in capture:
    result.n00b_proc_capture_stderr()
  if StdInFD in proxy or stdin != "":
    result.n00b_proc_proxy_stdin()
  if StdOutFD in proxy:
    result.n00b_proc_proxy_stdout()
  if StdErrFD in proxy:
    result.n00b_proc_proxy_stderr()

  result.n00b_proc_run(n00bTimeout)

  when defined(debug):
    trace("exit_code:   " & $result.exitCode)
    trace("stdout:      " & result.stdout)
    trace("stderr:      " & result.stderr)
  else:
    if result.exitCode > 0 and verbose:
      trace(strutils.strip(result.stderr & result.stdout))
