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
  libs     = ["pcre", "ssl", "crypto", "gumbo", "hatrack", "sodium"]

applyCommonLinkOptions()
staticLinkLibraries(libs, libDir, muslBase = localDir)

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
