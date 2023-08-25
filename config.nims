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
  var brew = staticexec("brew --prefix")
  var cpu = ""
  var target = ""
  if defined(arm):
    cpu = "arm64"
    target = "arm64"
  elif defined(amd64):
    cpu = "amd64"
    target = "x86_64"
  let openssldir = brew & "/opt/openssl@3/"
  switch("cpu", $cpu)
  switch("passc", "-flto " &
         "-target " & target & "-apple-macos11 " &
         "-I" & openssldir & "/include/")
  switch("passl", "-flto " &
         "-target " & target & "-apple-macos11 " &
         "-lcrypto.3 " &
          "-Wl,-object_path_lto,lto.o " &
          "-L " & openssldir & "/lib/")

else:
  switch("passl", "-static")

#switch("d", "release")
