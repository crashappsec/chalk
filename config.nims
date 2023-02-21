switch("d", "nimPreviewHashRef")
switch("d","ssl")
switch("debugger", "native")
if defined(macosx):
  switch("cpu", "arm64")
  switch("passc", "-flto -target arm64-apple-macos11")
  switch("passl", "-flto -target arm64-apple-macos11 -Wl,-object_path_lto,lto.o ")
#switch("d", "release")
