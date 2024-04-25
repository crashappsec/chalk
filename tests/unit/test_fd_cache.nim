# Import non-exported `newFDCache`, which is currently used only in these tests.
import ../../src/fd_cache {.all.}

proc withCache() =
  let
    testCache = newFDCache(size = 2)
    one1       = testCache.acquireFileStream("one")
    one2       = testCache.acquireFileStream("one")
    two        = testCache.acquireFileStream("two")
  doAssert(one1 == one2)
  doAssert(one1 != two)

  try:
    # should not be allowed to acquire file as one is not released
    discard testCache.acquireFileStream("three")
    doAssert(false)
  except:
    doAssert(true)

  testCache.releaseFileStream(one1)
  try:
    # should still not be allowed to acquire file as one is not released
    discard testCache.acquireFileStream("three")
    doAssert(false)
  except:
    doAssert(true)

  testCache.releaseFileStream(one2)
  # we can finally get three as all ones have been released
  let three      = testCache.acquireFileStream("three")

  testCache.releaseFileStream(two)
  let one3       = testCache.acquireFileStream("one")
  doAssert(one1 != one3)

  testCache.releaseFileStream(three)

  testCache.withFileStream("one", mode = fmRead, strict = true):
    doAssert(stream != nil)
  doAssert(stream == nil)

proc global() =
  withFileStream("one", mode = fmRead, strict = true):
    doAssert(stream != nil)
  doAssert(stream == nil)

proc main =
  withCache()
  global()

# Omit testing at compile time, which errors due to `getcwd`.
main()
