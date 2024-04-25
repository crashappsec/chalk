# Import non-exported `newFDCache`, which is currently used only in these tests.
import ../../src/fd_cache {.all.}

proc withCache() =
  let
    testCache = newFDCache(size = 2)
    one1       = testCache.acquireFileStream("one")
    one2       = testCache.acquireFileStream("one")
    two        = testCache.acquireFileStream("two")
  assert(one1 == one2)
  assert(one1 != two)

  try:
    # should not be allowed to acquire file as one is not released
    discard testCache.acquireFileStream("three")
    assert(false)
  except:
    assert(true)

  testCache.releaseFileStream(one1)
  try:
    # should still not be allowed to acquire file as one is not released
    discard testCache.acquireFileStream("three")
    assert(false)
  except:
    assert(true)

  testCache.releaseFileStream(one2)
  # we can finally get three as all ones have been released
  let three      = testCache.acquireFileStream("three")

  testCache.releaseFileStream(two)
  let one3       = testCache.acquireFileStream("one")
  assert(one1 != one3)

  testCache.releaseFileStream(three)

  testCache.withFileStream("one", mode = fmRead, strict = true):
    assert(stream != nil)
  assert(stream == nil)

proc global() =
  withFileStream("one", mode = fmRead, strict = true):
    assert(stream != nil)
  assert(stream == nil)

proc main =
  withCache()
  global()

# Omit testing at compile time, which errors due to `getcwd`.
main()
