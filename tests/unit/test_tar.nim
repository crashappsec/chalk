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

  ## Character classes [abc]
  check globMatch("a", "[abc]")
  check globMatch("b", "[abc]")
  check globMatch("c", "[abc]")
  check not globMatch("d", "[abc]")
  check not globMatch("/", "[abc]")

  ## Character class range [a-z]
  check globMatch("m", "[a-z]")
  check not globMatch("M", "[a-z]")
  check globMatch("9", "[0-9]")
  check not globMatch("a", "[0-9]")

  ## Negated class [!abc]
  check not globMatch("a", "[!abc]")
  check globMatch("d", "[!abc]")
  check not globMatch("/", "[!abc]")

  ## Classes inside longer patterns
  check globMatch("foo.c", "foo.[ch]")
  check globMatch("foo.h", "foo.[ch]")
  check not globMatch("foo.x", "foo.[ch]")

  ## Escape \x matches literal x
  check globMatch("*", "\\*")
  check not globMatch("a", "\\*")
  check globMatch("?", "\\?")
  check not globMatch("a", "\\?")

proc testIsExcluded() =
  ## No patterns: never excluded
  check not isExcluded("foo", @[])
  check not isExcluded("foo/bar", @[])

  ## Single positive pattern
  check isExcluded(".git", @[".git"])
  check not isExcluded("src", @[".git"])

  ## Docker semantics: no-slash patterns match by basename at any depth.
  check isExcluded("a/.git", @[".git"])          ## basename .git matches
  check isExcluded("a/b/.git", @[".git"])        ## basename .git matches
  check isExcluded("a/.git/config", @[".git"])   ## ancestor .git basename match
  check not isExcluded("a/b/src", @[".git"])     ## no match
  ## Ancestor check: files inside a matched dir are also excluded.
  check isExcluded(".git/config", @[".git"])
  check isExcluded(".git/hooks/pre-commit", @[".git"])

  ## Trailing-slash stripped; no-slash pattern matches by basename at any depth.
  check isExcluded("logs/app.log", @["logs/"])
  check isExcluded("a/logs/app.log", @["logs/"])  ## ancestor basename match

  ## Pattern with an internal '/' matches the full relative path only
  check isExcluded("build/output.o", @["build/*.o"])
  check not isExcluded("a/build/output.o", @["build/*.o"])

  ## Glob pattern without '/' matches by basename at any depth
  check isExcluded("foo.tmp", @["*.tmp"])
  check isExcluded("a/b/foo.tmp", @["*.tmp"])  ## basename match
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

proc testHasNegationForDir() =
  ## No-slash negation: always recurse (basename can match at any depth).
  check hasNegationForDir("logs", @["!*.log"])
  check hasNegationForDir("a/b", @["!important"])

  ## Literal-prefix slash negation: recurse into the targeted dir.
  check hasNegationForDir("logs", @["!logs/important.log"])
  check not hasNegationForDir("other", @["!logs/important.log"])

  ## ** negation: always recurse.
  check hasNegationForDir("logs", @["!**/important.log"])

  ## Wildcarded slash negation: recurse when the prefix glob-matches norm.
  check hasNegationForDir("logs_app",  @["!logs_*/important.log"])
  check not hasNegationForDir("other", @["!logs_*/important.log"])

  ## Multi-level norm with wildcarded prefix.
  check hasNegationForDir("a/b2",    @["!a/b[0-9]/file.txt"])
  check not hasNegationForDir("a/c", @["!a/b[0-9]/file.txt"])

  ## Positive patterns are ignored.
  check not hasNegationForDir("logs", @["logs/"])

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
  discard writeTarGz(
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
  discard writeTarGz(
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

  ## Wildcarded slash negation: logs_app/ excluded, but !logs_*/important.log
  ## re-includes the one file whose parent dir glob-matches logs_*.
  createDir(tmpDir / "logs_app")
  writeFile(tmpDir / "logs_app" / "important.log", "keep\n")
  writeFile(tmpDir / "logs_app" / "debug.log",     "drop\n")
  discard writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @["logs_app/", "!logs_*/important.log"],
  )
  let files3 = listTarGzFiles(outPath)
  check "logs_app/important.log" in files3
  check "logs_app/debug.log" notin files3

proc testSizeThreshold() =
  let tmpDir = getTempDir() / "test_tar_threshold"
  removeDir(tmpDir)
  createDir(tmpDir)
  let outPath = getTempDir() / "test_threshold_out.tar.gz"

  ## Directory-only context: no regular files, so threshold must still fire.
  createDir(tmpDir / "a")
  createDir(tmpDir / "a" / "b")
  createDir(tmpDir / "c")
  var raised = false
  try:
    discard writeTarGz(
      outPath        = outPath,
      contextPath    = tmpDir,
      patterns       = @[],
      sizeThreshold  = 1,
    )
  except TarSizeLimitError:
    raised = true
  check raised
  if fileExists(outPath):
    removeFile(outPath)

  ## Symlink-only context: no regular files, threshold must still fire.
  let symlinkDir = getTempDir() / "test_tar_symlinks"
  removeDir(symlinkDir)
  createDir(symlinkDir)
  createSymlink("/tmp", symlinkDir / "link")
  raised = false
  try:
    discard writeTarGz(
      outPath        = outPath,
      contextPath    = symlinkDir,
      patterns       = @[],
      sizeThreshold  = 1,
    )
  except TarSizeLimitError:
    raised = true
  check raised
  if fileExists(outPath):
    removeFile(outPath)

  ## Threshold not exceeded: no error raised.
  let smallDir = getTempDir() / "test_tar_small"
  removeDir(smallDir)
  createDir(smallDir)
  writeFile(smallDir / "tiny.txt", "hi\n")
  discard writeTarGz(
    outPath        = outPath,
    contextPath    = smallDir,
    patterns       = @[],
    sizeThreshold  = 1024 * 1024,
  )
  check fileExists(outPath)
  removeFile(outPath)

proc main() =
  testGlobMatch()
  testIsExcluded()
  testHasNegationForDir()
  testWriteTarGz()
  testSizeThreshold()

main()
