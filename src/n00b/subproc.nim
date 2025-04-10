import ./[c, types, util]

proc runCommand*(
  cmd: string,
  args: seq[string],
  proxy = false,
  capture = true,
): n00b_proc_t =
  when defined(debug):
    echo("cmd: ", cmd)
    echo("args: ", args)
  result = n00b_run_process(
    @(cmd),
    @(args),
    proxy = proxy,
    capture = capture,
  )

proc exitCode*(p: n00b_proc_t): int =
  result = int(n00b_proc_get_exit_code(p))
  when defined(debug):
    echo("exit_code: ", result)

proc stdout*(p: n00b_proc_t): string =
  result = $(n00b_proc_get_stdout_capture(p))
  when defined(debug):
    echo("stdout: ", result)

proc stderr*(p: n00b_proc_t): string =
  result = $(n00b_proc_get_stderr_capture(p))
  when defined(debug):
    echo("stderr: ", result)
