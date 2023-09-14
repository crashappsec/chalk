##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Helper used in jtiso

import os, strutils

{. emit: """
#include <dlfcn.h>
void forge_dlopen(char *path) {
  dlopen(path, RTLD_NOW|RTLD_GLOBAL);
}
""".}

proc forgeDlopenC(path: ptr cchar) {.importc:"forge_dlopen".}
proc loadLibrary(path: string) =
  var pathVar = path
  var pathPointer = cast[ptr cchar](addr(pathVar[0]))
  forgeDlopenC(pathPointer)

let args = commandLineParams()
if len(args) < 1:
  echo "usage: " & getAppFilename() & " <library.so>"
  quit(1)

let library = args[0]
loadLibrary(library)
var maps = open("/proc/self/maps").readAll().splitLines()
for line in maps:
  if line.contains(library):
    echo line.split(' ')[^1]
    quit(0)

let lastDitchEffort="/usr/lib/x86_64-linux-gnu/" & library
try:
  var fd = open(lastDitchEffort)
  fd.close()
  echo lastDitchEffort
except:
  quit(1)
quit(0)
