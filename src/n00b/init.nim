import std/[cmdline, envvars]
import ./[c, subproc]

proc setupN00b*() =
  # nim doesnt expose native C envp so need to manually reconstruct it
  var envs = newSeq[string]()
  for k, v in envPairs():
    envs.add(k & "=" & v)
  let
    args = commandLineParams()
    argv = allocCStringArray(args)
    envp = allocCStringArray(envs)
  n00b_init(
    cint(len(args)),
    argv,
    envp,
  )
  n00b_terminal_app_setup()

  echo("!!! n00b is here")
  let p = runCommand("/usr/bin/ls", @["."])
  echo("subproc done")
  discard p.exitCode()
  discard p.stdout()
  discard p.stderr()
