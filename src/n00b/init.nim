import std/[
  cmdline,
]
import ".."/[
  utils/envvars,
]

proc n00b_init(
  argc: cint,
  argv: pointer,
  envp: pointer,
) {.header:"n00b.h".}

proc n00b_terminal_app_setup() {.header:"n00b.h".}

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
