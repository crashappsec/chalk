import std/[algorithm, macros, os, parseutils, strscans, strutils]

func w(s: string, start: int): int =
  ## Returns the number of characters in `s` that are valid Nim identifier
  ## characters, beginning from `start`.
  ##
  ## This is a custom matcher for `scanf`. It is similar to the standard
  ## library's `$w` matcher, but it only skips (and does not bind).
  s.skipWhile(IdentChars, start)

proc getSortedPaths(
    dir: string, pc: PathComponent, relative: bool, pattern: static string
): seq[string] =
  ## Returns paths in `dir` of kind `pc` that match the given scanf `pattern`,
  ## in alphabetical order.
  ##
  ## If `relative` is `true`, the returned paths are relative to `dir`.
  result = @[]
  for kind, path in walkDir(dir, relative = relative):
    if kind == pc and path.scanf(pattern):
      result.add path
  sort result

proc getBracketedTestModules(): NimNode =
  ## Returns the AST for a `nnkBracket` containing the module names of Nim
  ## test files in this directory.
  const files = getSortedPaths(
    currentSourcePath().parentDir(), pcFile, relative = true, "test_$[w].nim$."
  )
  result = nnkBracket.newTree()
  for f in files:
    result.add ident(f[0 ..^ 5]) # Remove .nim file extension.
  expectMinLen(result, 1)

macro importTestFiles() =
  ## Imports every Nim module that begins with `test_` in this directory.
  let bracketedModules = getBracketedTestModules()
  result = newStmtList(
    quote do:
      import "."/`bracketedModules`
  )
  const thisFile = currentSourcePath().extractFilename()
  echo thisFile & ": 'importTestFiles' produced:\n" & result.repr

importTestFiles()
