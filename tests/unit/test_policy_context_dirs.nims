import std/os

# config.nims links libgit2 after OpenSSL; unlike the chalk binary, nothing in
# this test references OpenSSL before libgit2 does, so link it again after.
let libDir = getEnv("LOCAL_INSTALL_DIR", getEnv("HOME") / ".local/c0") / "libs"
switch("passL", libDir / "libssl.a")
switch("passL", libDir / "libcrypto.a")
