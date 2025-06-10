##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

template withAtomicVar*[T](x: var T, code: untyped) =
  let copy = x.deepCopy()
  try:
    code
  except:
    # restore variable to original value
    x = copy
    raise
