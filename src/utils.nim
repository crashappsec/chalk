## Various utility functions.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022

import std/sysrand
import times

template secureRand*[T](): T =
  ## Returns a uniformly distributed random value of any _sized_ type.
  runnableExamples:
    echo secureRand[uint64]()
    echo secureRand[int32]()
    echo secureRand[float]()
    echo secureRand[array[6, byte]]()
    # secureRand[str]() should crash w/ a string dereference, since str is nil

  var randBytes: array[sizeof(T), byte]

  discard(urandom(randBytes))

  cast[T](randBytes)

template dirWalk*(flag: bool, walker: untyped, body: untyped) =
  var item {.inject.}: string

  for i in walker(path):
    when flag:
      item = i.path
    else:
      item = i

    body
  
template unixTimeInMs*(): uint64 =
  # One oddity of NIM is that, if I put a decimal point here to make
  # it a float, I *have* to put a trailing zero. That in and of itself
  # is fine, but the error message when I don't sucks: 'Error: Invalid
  # indentation'
  const toMS = 1000000.0
  cast[uint64](epochTime() * toMS)
