import std/[os, osproc, parseopt, strformat, strutils]

type
  bypassCmd = enum
    bcNone
    bcDocker = "docker"
    bcExec = "exec"

proc err(msg: string) =
  ## Writes `msg` to stderr, then quits with an exit code of 1.
  stderr.writeLine &"error: {msg}"
  quit 1

proc handleBypass*() =
  ## Does nothing when the `CHALK_BYPASS` environment variable is unset.
  ##
  ## However, if that environment variable is set, and the command is:
  ##
  ## - `docker`: executes the rest of the command line with docker, without chalk.
  ##
  ## - `exec`: executes the rest of the command line, without chalk.
  ##
  ## - Something else or missing: quits with exit code 1.
  const bypassEnvVar = "CHALK_BYPASS"

  if getEnv(bypassEnvVar) == "":
    return

  var p = initOptParser()
  var bypassCmd = bcNone
  const msg =
    &"{bypassEnvVar} was set, but the chalk command is not '{bcDocker}' or '{bcExec}'. Quitting."

  for kind, key, _ in getopt(p):
    case kind
    of cmdArgument:
      case key
      of $bcDocker, $bcExec:
        bypassCmd = parseEnum[bypassCmd](key)
        break
      else:
        err(msg)
    of cmdShortOption, cmdLongOption:
      # Ignore any option that appears before an argument.
      discard
    of cmdEnd:
      err(msg)

  if bypassCmd == bcNone:
    err(msg)

  # Run the rest of the command line that appears after `docker` or `exec`.
  let cmd =
    case bypassCmd
    of bcDocker:
      $bcDocker & " " & cmdLineRest(p)
    of bcExec:
      cmdLineRest(p)
    of bcNone:
      doAssert false
      "" # Cannot happen.

  stderr.writeLine &"chalk: the {bypassEnvVar} environment variable is set."
  stderr.writeLine &"Running the following command without chalk:\n  {cmd}"
  let exitCode = execCmd(cmd)
  quit exitCode
