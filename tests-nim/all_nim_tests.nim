import std/[algorithm, macros, os, strutils]

proc getSortedPaths(dir: string, pc: PathComponent, relative: bool): seq[string] =
  ## Returns paths in `dir` of kind `pc` in alphabetical order.
  ##
  ## If `relative` is `true`, the returned paths are relative to `dir`.
  result = @[]
  for kind, path in walkDir(dir, relative = relative):
    if kind == pc:
      result.add path
  sort result

proc getBracketedTestModules(): NimNode =
  ## Returns the AST for a `nnkBracket` containing the module names of Nim
  ## test files in this directory.
  const files = getSortedPaths(currentSourcePath().parentDir(), pcFile, relative = true)
  result = nnkBracket.newTree()
  for f in files:
    if f.startsWith("test_") and f.endsWith(".nim") and f.len > 9:
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
