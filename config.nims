import std/os
import ./src/nimscript

# Always take the release build unless -d:debug is explicitly passed.
# Nim debug builds are shockingly slow.
when not defined(debug):
  switch("d", "release")
  switch("opt", "speed")
  switch("warning", "Deprecated:off")
  switch("warning", "User:off")
else:
  switch("debugger", "native")

switch("d", "ssl")
switch("d", "nimPreviewHashRef")
switch("gc", "refc")
switch("path", ".")
switch("d", "useOpenSSL3")
# Disable some errors for Clang 15+ and GCC 14+.
switch("passC", "-Wno-error=int-conversion")
switch("passC", "-Wno-error=implicit-function-declaration")
switch("passC", "-Wno-error=incompatible-pointer-types")
switch("passC", "-std=c23")
switch("passC", "-D_POSIX_C_SOURCE=200809L")

when defined(macosx):
  switch("cpu", getTargetArch())
  switch("passc", "-flto -target " & getTargetStr())
  switch("passl", "-flto -w -target " & getTargetStr() & "-Wl,-object_path_lto,lto.o")
elif defined(linux):
  switch("passc", "-static")
  switch("passl", "-static")
  switch("gcc.exe",       "musl-gcc")
  switch("gcc.linkerexe", "musl-gcc")
else:
  echo "Platform not supported."
  quit(1)

var
  nimutils    = getCurrentDir().parentDir().joinPath("nimutils")
  n00bDist    = getCurrentDir().parentDir().joinPath("n00b", "dist")

staticLinkLibraries(
  [
    "n00b",
    "git2",
    "curl",
    "ssl",
    "crypto",
    "http_parser",
    "pcre2-8",
    "backtrace",
    "ffi",
    "unibreak",
    "utf8proc",
    "quark",
    "z",
  ],
  n00bDist.joinPath("lib"),
)
switch("cincludes", n00bDist.joinPath("include"))

staticLinkLibraries(
  [
    "gumbo",
    "pcre",
  ],
  nimutils.joinPath("files", "deps", "lib", "linux-" & getTargetArch()),
)
switch("cincludes", nimutils.joinPath("nimutils", "c"))

# n00b
switch("passC", "-DHATRACK_PER_INSTANCE_AUX")
switch("passC", "-DHATRACK_DONT_DEALLOC")
switch("passC", "-DN00B_DEBUG")
switch("passC", "-DN00B_DEV")
switch("passC", "-DN00B_FULL_MEMCHECK")
switch("passC", "-DHATRACK_ALLOC_PASS_LOCATION")

# https://nim-lang.org/docs/nimc.html
# > --styleCheck:usages
# > only enforce consistent spellings of identifiers, do not enforce the style on declarations
# https://github.com/nim-lang/Nim/blob/4680ab61c06782d142492d1fcdebf8e942373c09/changelogs/changelog_1_6_0.md#compiler-messages-error-messages-hints-warnings
# To be enabled, this has to be combined either with --styleCheck:error or --styleCheck:hint.
switch("styleCheck", "usages")
switch("styleCheck", "error")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
