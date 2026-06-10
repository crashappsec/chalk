import std/[
  os,
  osproc,
  strutils,
]
import ../../src/docker/tar
import ../equivalency/dockerignore/check_nim

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

## ---------------------------------------------------------------------------
## testGlobMatch
##
## Tests the raw globMatch() function (path-component-aware pattern matching
## without ancestor-directory propagation).
##
## Test cases derived from moby/patternmatcher matchTests
## (https://github.com/moby/patternmatcher/blob/main/patternmatcher_test.go),
## which test the low-level filepath.Match-like pattern matching.
## Cases that depend on the ancestor-propagation logic of Matches() /
## MatchesOrParentMatches() are tested via runEquivalencyTests() below.

proc testGlobMatch() =
  ## Exact match
  check globMatch("abc", "abc")
  check not globMatch("abc", "def")
  check globMatch("", "")
  check not globMatch("abc", "")
  check not globMatch("", "abc")
  check globMatch("abc.def", "abc.def")
  check not globMatch("abc.def", "abcdef")
  check not globMatch("abc.def", "abcZdef")

  ## * matches any run of non-separator characters
  check globMatch("abc", "*")
  check not globMatch("a/b", "*")
  check globMatch("abc", "*c")
  check globMatch("a", "a*")
  check globMatch("abc", "a*")
  check not globMatch("ab/c", "a*")      ## * never crosses /
  check globMatch("abc/b", "a*/b")
  check not globMatch("a/c/b", "a*/b")
  check globMatch("axbxcxdxe/f", "a*b*c*d*e*/f")
  check globMatch("axbxcxdxexxx/f", "a*b*c*d*e*/f")
  check not globMatch("axbxcxdxe/xxx/f", "a*b*c*d*e*/f")
  check not globMatch("axbxcxdxexxx/fff", "a*b*c*d*e*/f")
  check globMatch("abxbbxdbxebxczzx", "a*b?c*x")
  check not globMatch("abxbbxdbxebxczzy", "a*b?c*x")
  check globMatch("xxx", "*x")

  ## ? matches any single non-separator character
  check globMatch("abcZdef", "abc?def")
  check not globMatch("abcdef", "abc?def")
  check not globMatch("a/b", "a?b")     ## ? never crosses /
  check not globMatch("a/b", "a*b")     ## * never crosses /

  ## character classes [abc], [a-z], [!a-z]
  check globMatch("abc", "ab[c]")
  check globMatch("abc", "ab[b-d]")
  check not globMatch("abc", "ab[e-g]")
  check not globMatch("abc", "ab[^c]")
  check not globMatch("abc", "ab[^b-d]")
  check globMatch("abc", "ab[^e-g]")
  check not globMatch("/", "[abc]")     ## / never matches inside []

  ## dot patterns
  check globMatch(".foo", ".*")
  check not globMatch("foo", ".*")

  ## Escape \x matches literal x
  check globMatch("*", "\\*")
  check not globMatch("a", "\\*")
  check globMatch("?", "\\?")
  check not globMatch("a", "\\?")

  ## ** at end: matches everything rooted at prefix
  check globMatch("abc/def", "abc/**")
  check globMatch("abc/def/ghi", "abc/**")
  check not globMatch("abc", "abc/**")  ## requires at least one component

  ## ** at start: suffix match (no '/' after **): any position including mid-component
  check globMatch("file", "**")
  check globMatch("dir/file", "**")
  check globMatch("dir/dir/file", "**")
  check globMatch("file", "**file")
  check globMatch("dir/file", "**file")
  check globMatch("dir/dir/file", "**file")
  check globMatch("dir/dir/file.txt", "**/file*.txt")
  check not globMatch("dir/dir/file.txt", "**/**/*.txt2")

  ## **/ prefix: boundary match only (suffix must start at a path boundary)
  check globMatch("dir/file", "**/file")
  check globMatch("dir/dir/file", "**/file")
  check globMatch(".foo", "**/.foo")
  check not globMatch("bar.foo", "**/.foo")   ## bar.foo does not have '/.foo' as suffix
  check globMatch("dir/.foo", "**/.foo")
  check globMatch("foo/bar", "**/foo/bar")
  check globMatch("dir/foo/bar", "**/foo/bar")
  check globMatch("dir/dir2/foo/bar", "**/foo/bar")

  ## ** in middle
  check globMatch("dir/dir2/file", "**/dir2/*")
  check globMatch("dir/dir2/dir3/file", "**/dir2/**")
  check globMatch("dir/dir/file.txt", "**/**/*.txt")
  check globMatch("file.txt", "**/*.txt")
  check globMatch("file.txt", "**/**/*.txt")

  ## a** (** not at position 0): anchored prefix then wildcard-suffix
  check globMatch("a/file.txt", "a**/*.txt")
  check globMatch("a/dir/file.txt", "a**/*.txt")
  check globMatch("a/dir/dir/file.txt", "a**/*.txt")
  check not globMatch("a/dir/file.txt", "a/*.txt")   ## single * does not cross /
  check globMatch("a/file.txt", "a/*.txt")

  ## special characters that are regex meta but not glob meta
  check globMatch("a(b)c/def", "a(b)c/def")
  check not globMatch("a(b)c/xyz", "a(b)c/def")
  check globMatch("a.|)$(}+{bc", "a.|)$(}+{bc")
  check globMatch(
    "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl",
    "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl",
  )
  check globMatch(
    "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl",
    "dist/*.whl",
  )


## ---------------------------------------------------------------------------
## testHasNegationForDir
##
## Tests hasNegationForDir(), which decides whether to recurse into a
## directory that is otherwise excluded.

proc testHasNegationForDir() =
  ## No-slash negation: recurse only when the pattern matches norm itself.
  check not hasNegationForDir("logs", @["!*.log"])    ## '*.log' doesn't match 'logs'
  check not hasNegationForDir("a/b", @["!important"]) ## 'important' doesn't match 'a/b'
  check hasNegationForDir("logs", @["!logs"])         ## 'logs' matches 'logs'
  check hasNegationForDir("foo", @["!foo"])
  check not hasNegationForDir("bar", @["!foo"])

  ## Literal-prefix slash negation: recurse into the targeted dir.
  check hasNegationForDir("logs", @["!logs/important.log"])
  check not hasNegationForDir("other", @["!logs/important.log"])

  ## ** negation: always recurse.
  check hasNegationForDir("logs", @["!**/important.log"])
  check hasNegationForDir("a/b", @["!**/important.log"])

  ## Wildcarded slash negation: recurse when prefix glob-matches norm.
  check hasNegationForDir("logs_app", @["!logs_*/important.log"])
  check not hasNegationForDir("other", @["!logs_*/important.log"])

  ## Multi-level norm with wildcarded prefix.
  check hasNegationForDir("a/b2", @["!a/b[0-9]/file.txt"])
  check not hasNegationForDir("a/c", @["!a/b[0-9]/file.txt"])

  ## Empty pattern list: never recurse.
  check not hasNegationForDir("logs", @[])

  ## Positive patterns are ignored.
  check not hasNegationForDir("logs", @["logs/"])


## ---------------------------------------------------------------------------
## testWriteTarGz

proc listTarGzFiles(path: string): seq[string] =
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

  ## With slash-prefix negation: logs/ excluded but logs/*.log re-included.
  discard writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @["logs/", "!logs/*.log", "secrets/"],
  )
  let files = listTarGzFiles(outPath)

  check "app.py" in files
  check "logs/debug.log" in files
  check "logs/app.log" in files
  check "logs/temp.tmp" notin files
  check "secrets/api_key.txt" notin files
  check "secrets" notin files

  ## Without negation: entire logs/ subtree absent.
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

  ## Wildcarded slash negation: logs_app/ excluded, !logs_*/important.log re-includes.
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

  ## Symlink: entry appears in archive with correct target.
  let symlinkDir = getTempDir() / "test_tar_symlink_content_" & $getCurrentProcessId()
  createDir(symlinkDir)
  defer:
    removeDir(symlinkDir)
  createSymlink("/etc/hostname", symlinkDir / "link_to_hostname")
  discard writeTarGz(
    outPath     = outPath,
    contextPath = symlinkDir,
    patterns    = @[],
  )
  let (tarVerbose, tarRc) = execCmdEx("tar tvf " & outPath)
  check tarRc == 0
  ## tar -tv output includes the symlink target after ' -> '
  check "link_to_hostname" in tarVerbose
  check "/etc/hostname" in tarVerbose


## ---------------------------------------------------------------------------
## testSizeThreshold

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

## ---------------------------------------------------------------------------
## testMaxFileSize

proc testMaxFileSize() =
  let tmpDir  = getTempDir() / "test_tar_maxfile_" & $getCurrentProcessId()
  let outPath = getTempDir() / "test_maxfile_out_" & $getCurrentProcessId() & ".tar.gz"
  createDir(tmpDir)
  defer:
    removeDir(tmpDir)
    removeFile(outPath)

  ## small.txt: 10 bytes -- below limit
  ## large.txt: 2000 bytes -- above limit
  writeFile(tmpDir / "small.txt", repeat('x', 10))
  writeFile(tmpDir / "large.txt", repeat('y', 2000))

  let skipped = writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @[],
    maxFileSize = 100,
  )

  ## large.txt must appear in the skipped list
  check skipped.len == 1
  check skipped[0].path == "large.txt"
  check skipped[0].size == 2000
  ## hash must be a non-empty hex string
  check skipped[0].hash.len > 0
  for c in skipped[0].hash:
    check c in {'0'..'9', 'a'..'f'}

  ## archive must contain small.txt but not large.txt
  let files = listTarGzFiles(outPath)
  check "small.txt" in files
  check "large.txt" notin files


## ---------------------------------------------------------------------------
## testLongPaths

proc testLongPaths() =
  ## Paths longer than 100 chars require a GNU LongLink preamble entry.
  ## Verify that writeTarGz emits a readable archive for such paths.
  let tmpDir  = getTempDir() / "test_tar_longpath_" & $getCurrentProcessId()
  let outPath = getTempDir() / "test_longpath_out_" & $getCurrentProcessId() & ".tar.gz"

  ## Build a path that exceeds the 100-char ustar name field.
  let longDir = "a_reasonably_long_directory_name_that_pushes_limits" /
                "another_long_subdirectory_name_to_exceed_one_hundred"
  createDir(tmpDir / longDir)
  writeFile(tmpDir / longDir / "file_with_a_long_name_too.txt", "data\n")
  defer:
    removeDir(tmpDir)
    removeFile(outPath)

  discard writeTarGz(
    outPath     = outPath,
    contextPath = tmpDir,
    patterns    = @[],
  )

  let files = listTarGzFiles(outPath)
  let expected = longDir / "file_with_a_long_name_too.txt"
  check expected.len > 100
  check expected in files


## ---------------------------------------------------------------------------
## testToOctal

proc testToOctal() =
  ## Normal values fit in their field widths.
  check toOctal(0, 11)    == "00000000000"
  check toOctal(7, 11)    == "00000000007"
  check toOctal(8, 11)    == "00000000010"
  check toOctal(511, 11)  == "00000000777"
  check toOctal(512, 11)  == "00000001000"

  ## Maximum value for an 11-digit octal field: 8^11 - 1 = 8589934591 (~8 GiB).
  let maxVal = int64(8589934591)  ## 077777777777 octal
  check toOctal(maxVal, 11) == "77777777777"

  ## One byte over the 11-digit limit must raise.
  var raised = false
  try:
    discard toOctal(maxVal + 1, 11)
  except ValueError:
    raised = true
  check raised

  ## 6-digit checksum field: max 262143 (0777777 octal).
  check toOctal(0, 6)      == "000000"
  check toOctal(262143, 6) == "777777"
  raised = false
  try:
    discard toOctal(262144, 6)
  except ValueError:
    raised = true
  check raised


proc main() =
  testGlobMatch()
  runEquivalencyTests()
  testHasNegationForDir()
  testToOctal()
  testWriteTarGz()
  testMaxFileSize()
  testLongPaths()
  testSizeThreshold()

main()
