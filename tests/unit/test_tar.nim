import std/[os, osproc, strutils]
import ../../src/docker/tar

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

proc testGlobMatch() =
  ## Exact matches
  check globMatch("foo", "foo")
  check not globMatch("foo", "bar")
  check globMatch("", "")
  check not globMatch("foo", "")
  check not globMatch("", "foo")

  ## * matches any run of non-separator characters
  check globMatch("foo.nim", "*.nim")
  check globMatch("foo", "*")
  check not globMatch("a/foo.nim", "*.nim")
  check not globMatch("foo/bar", "*")

  ## * at end
  check globMatch("foo/bar", "foo/*")
  check not globMatch("foo/bar/baz", "foo/*")

  ## * in middle
  check globMatch("foo.nim", "foo.*")
  check globMatch("fooxbar", "foo*bar")
  check not globMatch("foo/bar", "foo*bar")

  ## ? matches any single non-separator character
  check globMatch("foo", "f?o")
  check globMatch("fao", "f?o")
  check not globMatch("fo", "f?o")
  check not globMatch("fooo", "f?o")
  check not globMatch("f/o", "f?o")

  ## ** matches across path separators
  check globMatch("a/b/c.nim", "**/*.nim")
  check globMatch("foo.nim", "**/*.nim")
  check globMatch("a/b/c", "**")
  check globMatch("foo", "**")
  check globMatch("a/b/c/d", "a/**/d")
  check globMatch("a/d", "a/**/d")
  check not globMatch("a/b/c/e", "a/**/d")

  ## ** at end
  check globMatch("a/b/c", "a/**")
  check globMatch("a/b", "a/**")
  check not globMatch("b/c", "a/**")

  ## Trailing characters after **
  check globMatch("src/docker/tar.nim", "src/**/*.nim")
  check not globMatch("src/docker/tar.c", "src/**/*.nim")

proc testIsExcluded() =
  ## No patterns: never excluded
  check not isExcluded("foo", @[])
  check not isExcluded("foo/bar", @[])

  ## Single positive pattern
  check isExcluded(".git", @[".git"])
  check not isExcluded("src", @[".git"])

  ## Pattern without '/' matches against every path component
  check isExcluded("a/.git", @[".git"])
  check isExcluded("a/b/.git", @[".git"])
  check isExcluded("a/.git/config", @[".git"])
  check not isExcluded("a/b/src", @[".git"])

  ## Trailing-slash patterns have the slash stripped, so they match any
  ## path component at any depth (same as the no-slash form)
  check isExcluded("logs/app.log", @["logs/"])
  check isExcluded("a/logs/app.log", @["logs/"])

  ## Pattern with an internal '/' matches the full relative path only
  check isExcluded("build/output.o", @["build/*.o"])
  check not isExcluded("a/build/output.o", @["build/*.o"])

  ## Glob pattern without '/'
  check isExcluded("foo.tmp", @["*.tmp"])
  check isExcluded("a/b/foo.tmp", @["*.tmp"])
  check not isExcluded("foo.nim", @["*.tmp"])

  ## Last-match-wins: later patterns override earlier ones
  check not isExcluded(
    "logs/important.log",
    @["logs/", "!logs/important.log"],
  )
  check isExcluded(
    "logs/other.log",
    @["logs/", "!logs/important.log"],
  )

  ## Negation re-includes after exclusion
  check not isExcluded(
    "keep.tmp",
    @["*.tmp", "!keep.tmp"],
  )
  check isExcluded(
    "other.tmp",
    @["*.tmp", "!keep.tmp"],
  )

  ## Chalk config patterns (appended last) take final precedence
  ## over .dockerignore patterns
  check isExcluded(
    "logs/important.log",
    @["logs/", "!logs/important.log", "logs/"],
  )
  check not isExcluded(
    "logs/important.log",
    @["logs/", "logs/", "!logs/important.log"],
  )

  ## ** glob in isExcluded
  check isExcluded("a/b/secret.key", @["**/*.key"])
  check not isExcluded("a/b/secret.pub", @["**/*.key"])

proc listTarGzFiles(path: string): seq[string] =
  ## Return all entry names from a .tar.gz archive using the system tar command.
  let (output, exitCode) = execCmdEx("tar tf " & path)
  doAssert exitCode == 0, "tar tf failed: " & output
  result = @[]
  for line in output.splitLines():
    let l = line.strip().strip(chars = {'/'})
    if l.len > 0:
      result.add(l)

proc testWriteTarGz() =
  let tmpDir  = getTempDir() / "test_tar_" & $getCurrentProcessId()
  let outPath = getTempDir() / "test_ctx_" & $getCurrentProcessId() & ".tar.gz"
  createDir(tmpDir / "logs")
  createDir(tmpDir / "secrets")
  writeFile(tmpDir / "app.py",               "print('hello')\n")
  writeFile(tmpDir / "logs" / "debug.log",   "debug\n")
  writeFile(tmpDir / "logs" / "app.log",     "app\n")
  writeFile(tmpDir / "logs" / "temp.tmp",    "scratch\n")
  writeFile(tmpDir / "secrets" / "api_key.txt", "s3cr3t\n")

  defer:
    removeDir(tmpDir)
    removeFile(outPath)

  ## With negation: logs/ excluded but *.log files re-included.
  writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @["logs/", "!logs/*.log", "secrets/"],
  )
  let files = listTarGzFiles(outPath)

  ## Files that must be present
  check "app.py" in files
  check "logs/debug.log" in files
  check "logs/app.log" in files

  ## Files that must be absent
  check "logs/temp.tmp" notin files
  check "secrets/api_key.txt" notin files
  check "secrets" notin files

  ## Without negation: entire logs/ subtree must be absent.
  writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @["logs/", "secrets/"],
  )
  let files2 = listTarGzFiles(outPath)

  check "app.py" in files2
  check "logs/debug.log" notin files2
  check "logs/app.log" notin files2
  check "logs/temp.tmp" notin files2
  check "secrets/api_key.txt" notin files2

proc main() =
  testGlobMatch()
  testIsExcluded()
  testWriteTarGz()

main()
