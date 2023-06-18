switch("d", "nimPreviewHashRef")
switch("d", "ssl")
switch("d", "useOpenSSL3")
switch("debugger", "native")

when (NimMajor, NimMinor) < (1, 7):
  # Locklevels never worked and are gone but older versions will complain.
  switch("warning", "LockLevel:off")
when (NimMajor, NimMinor, NimPatch) >= (1, 6, 12):
  # Someone made a move to deprecate, but they're undoing it.
  switch("warning", "BareExcept:off")

if defined(macosx):
  let openssldir = "/opt/homebrew/opt/openssl@3.0/lib"
  #switch("dynlibOverride","ssl")
  switch("cpu", "arm64")
  switch("passc", "-flto -target arm64-apple-macos11 ")
  switch("passl", "-flto -target arm64-apple-macos11 -Wl,-object_path_lto,lto.o")
#switch("d", "release")
