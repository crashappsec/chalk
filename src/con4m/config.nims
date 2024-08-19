import nimutils/nimscript, os

#switch("define", "testCases")
#switch("debugger", "native")

when not defined(debug):
  switch("d", "release")
  switch("opt", "speed")


applyCommonLinkOptions()

var
  default  = getEnv("HOME").joinPath(".local/c0")
  localDir = getEnv("LOCAL_INSTALL_DIR", default)
  libDir   = localdir.joinPath("libs")
  libs     = ["pcre", "ssl", "crypto", "gumbo", "hatrack"]

applyCommonLinkOptions()
staticLinkLibraries(libs, libDir, muslBase = localDir)
