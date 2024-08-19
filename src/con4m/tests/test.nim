import unittest, nimutils, macros, os, strutils, osproc

let passString = toAnsiCode(acBGreen) & "[PASSED]" & toAnsiCode(acReset)
let failString = toAnsiCode(acBRed)   & "[FAILED]" & toAnsiCode(acReset)
var fails = 0

macro runTests(dir: static[string], cmd: untyped): untyped =
  result = newStmtList()

  let dirpath = staticExec("pwd") & "/" & dir & "/"
  for filepath in staticListFiles(dirpath & "*.c4m"):
    let
      (dname, fname, ext) = filepath.splitFile()

    result.add quote do:
      try:
        let
          cmdline = `cmd` & `filepath`
        echo "running: ", cmdline
        let
          output  = execCmdEx(cmdline).output.strip()
          kat     = open(`dname` & "/" & `fname` & ".kat").readAll().strip()

        if output == kat:
          echo passString & " Test " & `fname`
        else:
          fails = fails + 1
          echo failString & " test " & `fname`
          echo "GOT:"
          echo output
          echo "EXPECTED: "
          echo kat
      except:
        fails = fails + 1
        echo "Exception raised: "
        echo getStackTrace()
        echo getCurrentExceptionMsg()


macro runStackTests(dir: static[string], cmd: untyped): untyped =
  result = newStmtList()

  let toppath = staticExec("pwd") & "/" & dir & "/"
  for filepath in staticListFiles(toppath):
    if filepath.endsWith(".kat"):
      continue
    let
      (dname, fname, ext) = filepath.splitFile()
      katfile             = toppath & dname & ".kat"
      dirpath             = joinPath(toppath, filepath)
      stacklist           = staticListFiles(dirpath)
      testname            = "stack-" & dname
    var
      stackFiles: seq[string] = @[]

    for item in stackList:
      stackFiles.add(joinPath(dirpath, item))

    let
      stackstr = stackfiles.join(" ")

    result.add quote do:
      try:
        let
          cmdline = `cmd` & `stackstr`
        echo "running: ", cmdline
        let
          output  = execCmdEx(cmdline).output.strip()
          kat     = open(`katfile`).readAll().strip()

        if output == kat:
          echo passString & " Test " & `testname`
        else:
          fails = fails + 1
          echo failString & " test " & `testname`
          echo "GOT:"
          echo output
          echo "EXPECTED: "
          echo kat
      except:
        fails = fails + 1
        echo "Exception raised: "
        echo getStackTrace()
        echo getCurrentExceptionMsg()

runTests("basics"):
  "./con4m --no-color --none "

runTests("spec"):
  "./con4m --no-color --none --c42 "

runStackTests("stack"):
  "./con4m --no-color --none "

check fails == 0
