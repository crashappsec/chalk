## Reads testcases.json and verifies each case against our Nim
## isExcluded() implementation.  Exit code 0 = all pass, 1 = failures.
##
## Importable: call runEquivalencyTests() from another test module.
## Standalone: nim c -r check_nim.nim
## Via make:   make unit-tests args="pattern tests/equivalency/dockerignore/check_nim.nim"
##
## See equivalency_test.go for the Go side of the same test cases.

import std/[
  json,
  os,
  sequtils,
  strutils,
]
import "../../../src/docker/tar"

const casesPath = currentSourcePath().parentDir() / "testcases.json"

proc runEquivalencyTests*() =
  let root = parseJson(readFile(casesPath))
  for node in root:
    let
      comment  = node["comment"].getStr()
      patterns = node["patterns"].elems.mapIt(it.getStr())
      path     = node["path"].getStr()
      expected = node["expected"].getBool()
      got      = isExcluded(path, patterns)
    doAssert got == expected,
      "FAIL: " & comment &
      "\n  patterns : " & $patterns &
      "\n  path     : " & path &
      "\n  expected : " & $expected &
      "\n  got      : " & $got

when isMainModule:
  runEquivalencyTests()
  echo "all dockerignore equivalency tests passed"
