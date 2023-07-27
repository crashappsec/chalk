## Make sure multiple chalk exes don't invoke each other in a
## recursive loop.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import config

const recursionEnvVar = "CHALK_INVOCATIONS"

proc recursionCheck*() =
  if not existsEnv(recursionEnvVar):
    putEnv(recursionEnvVar, "1")
    return

  let cur = getEnv(recursionEnvVar)

  try:
    let
      num   = parseInt(cur)
      limit = chalkConfig.getRecursiveExecLimit()
    if num >= limit:
      error(
        "Chalk is calling chalk recursively. This might happen in cases " &
        "where chalk is impersonating another command, if that command " &
        "might end up execing chalk or execing itself.  If the recursion " &
        "is expected, then set 'recursive_exec_limit' to a higher value " &
        "in your config (current limit is: " & $(limit) & ")")
      quit(-1)
    else:
      putEnv(recursionEnvVar, $(num + 1))
  except:
    putEnv(recursionEnvVar, "1")
