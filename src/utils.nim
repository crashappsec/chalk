## Various utility functions.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022

import std/sysrand
import times
import os

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

proc tildeExpand(s: string): string {.inline.} =
  var homedir = os.getHomeDir()

  if homedir[^1] == '/':
    homedir.setLen(len(homedir) - 1)
  if s == "":
    return homedir

  let parentFolder = homedir.splitPath().head

  return os.joinPath(parentFolder, s)

proc resolvePath*(inpath: string): string =
  # First, resolve tildes, as Nim doesn't seem to have an API call to
  # do that for us.
  var cur: string

  if inpath == "": return getCurrentDir()
  if inpath[0] == '~':
    let ix = inpath.find('/')
    if ix == -1:
      return tildeExpand(inpath[1 .. ^1])
    cur = joinPath(tildeExpand(inpath[1 .. ix]), inpath[ix+1 .. ^1])
  else:
    cur = inpath
  return cur.normalizedPath().absolutePath()

when isMainModule:
  echo resolvePath("~")
  echo resolvePath("")
  echo resolvePath("~fred")
  echo resolvePath("../../src/../../eoeoeo")


