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
  var
    host, target: string
    pwd = staticExec("pwd")

  when defined(doAmd64Build):
    host   = "amd64"
    target = "x86_64-apple-macos11"
  else:
    host   = "arm64"
    target = "arm64-apple-macos11"

  switch("cpu", host)
  switch("passc", "-flto -target " & target)
  switch("passl", "-flto -target " & target & "-Wl,-object_path_lto,lto.o")
else:
  switch("passl", "-static")
