import std/strutils
import ../../src/run_management

proc assertChunkedIdFormat(rawHash: string) =
  let formatted = idFormat(rawHash)
  let parts = formatted.split("-")
  let maxSizes = [6, 4, 4, 6]

  doAssert len(parts) <= len(maxSizes)
  doAssert formatted == idFormat(rawHash)
  for i in 0 ..< len(parts):
    doAssert len(parts[i]) <= maxSizes[i]

proc main() =
  assertChunkedIdFormat("")
  assertChunkedIdFormat("abcd")

  let formatted = idFormat("0123456789abcdef0123456789abcdef")
  doAssert formatted.count("-") == 3
  let parts = formatted.split("-")
  doAssert len(parts) == 4
  doAssert len(parts[0]) == 6
  doAssert len(parts[1]) == 4
  doAssert len(parts[2]) == 4
  doAssert len(parts[3]) == 6

main()
