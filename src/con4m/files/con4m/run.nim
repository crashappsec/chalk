##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import types, options, st, streams, os, nimutils, json, strutils

proc perLineWrap*(s: string,
                  startingMaxLineWidth = -1,
                  firstHangingIndent   = 2,
                  remainingIndents     = 0,
                  splitLongWords       = true,
                  seps: set[char]      = Whitespace,
                  newLine              = "\n"): string =
  ## deprecated; no longer does what it says either.
  return s.indentWrap(startingMaxLineWidth, firstHangingIndent, splitLongWords,
                      seps, newLine)
# This stuff comes before some imports because Nim sucks at forward referencing.
var config: AttrScope = nil

proc setConfigState*(s: AttrScope) =
  config = s

proc getConfigState(): AttrScope =
  if config == nil: config = AttrScope()
  return config

proc getConf*[T](s: string): Option[T] =
  return getOpt[T](getConfigState(), s)

import st, stack

template cmdLineErrorOutput(msg: string) =
    let formatted = `$`(color( "error: ", "red")).strip() & msg
    stderr.writeLine(formatted)
    quit(1)

proc tryToOpen*(f: string): Stream =
  if f.fileExists():
    try:
      return newFileStream(f)
    except:
      cmdLineErrorOutput("Error: could not open external config file " &
                         "(permissions issue?)")
  else:
    cmdLineErrorOutput(f & ": file not found.")

proc outputResults*(ctx: ConfigState) =
  case (getConf[string]("output_style")).get()
  of "pretty": echo $(ctx.attrs)
  of "raw": echo ctx.attrs.scopeToJson()
  of "json":
    let raw = ctx.attrs.scopeToJson()
    stderr.writeLine($color("Results:", "red"))
    stderr.writeLine(parseJson(raw).pretty())

  else: discard

template safeRun(stack: ConfigStack, backtrace = false) =
  try:
    stack.errored = false
    discard stack.run(backtrace)
  except:
    stack.errored = true
    getCurrentExceptionMsg().cmdLineErrorOutput()

proc con4mRun*(files, specs: seq[string]) =
  let
    scope = if len(specs) > 1: srsBoth else: srsConfig
    stubs = (getConf[seq[string]]("stubs")).getOrElse(@[])
    stack = newConfigStack().addSystemBuiltins(which=scope).addStubs(stubs)
    ctx   = stack.run().get()
    whens = getConf[seq[string]]("output_when").get()

  for specfile in specs:
    let
      fname  = specfile.resolvePath()
      stream = tryToOpen(fname)
    # TODO: add spec_whens
    stack.addSpecLoad(fname, stream)

  for i, filename in files:
    var addOut = false
    let
      fname  = filename.resolvePath()
      stream = tryToOpen(fname)
    stack.addConfLoad(fname, stream)
    if "all" in whens: addOut = true
    else:
      if i == 0 and "first" in whens: addOut = true
      if i == len(files) - 1 and "last" in whens: addOut = true
      if "rest" in whens and i != 0 and i != len(files) - 1: addOut = true

    if addOut:
      stack.addCallback(outputResults)

  stack.safeRun(backtrace = true)

proc specGenRun*(files: seq[string]) =
  let
    stubs = (getConf[seq[string]]("stubs")).getOrElse(@[])
    stack = newConfigStack().addSystemBuiltins(which=srsValidation).
            addGetoptSpecLoad()

  for item in files:
    let
      fname  = item.resolvePath()
      stream = tryToOpen(fname)

    stack.addSpecLoad(fname, stream)

  stack.addCodeGen(getConf[string]("language").get(),
                   getConf[string]("output_file").getOrElse(""))
  stack.safeRun(backtrace = true)
  echo $color("Code generation successful.", "atomiclime")
