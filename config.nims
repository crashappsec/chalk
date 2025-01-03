import std/os
import pkg/[nimutils/nimscript]

# This will end up yielding lto warnings. Uncomment if you want to load in gdb
# switch("debugger", "native")

# Always take the release build unless -d:debug is explicitly passed.
# Nim debug builds are shockingly slow.
when not defined(debug):
    switch("d", "release")
    switch("opt", "speed")
    switch("warning", "Deprecated:off")
    switch("warning", "User:off")

var
  default  = getEnv("HOME").joinPath(".local/c0")
  localDir = getEnv("LOCAL_INSTALL_DIR", default)
  libDir   = localdir.joinPath("libs")
  libs     = [
    "n00b",
    "curl",
    "ssl",
    "crypto",
    "pcre",
    "backtrace",
    "ffi",
    "unibreak",
    "utf8proc",
    "gumbo",
  ]

applyCommonLinkOptions()
staticLinkLibraries(
  libs,
  libDir,
  muslBase = localDir,
  useMusl = true,
)
