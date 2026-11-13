import std/options
import ../../src/podman/cmdline
import ../../src/podman/notice
import ../../src/podman/types

proc expectQuiet(args: seq[string], expected: bool) =
  let route = classifyPodmanArgs(args)
  doAssert route.kind == prInstrument, $args
  doAssert route.spec.quietOutput == expected, $args

proc expectInvalidBool(args: seq[string], flag: string) =
  let route = classifyPodmanArgs(args)
  doAssert route.kind == prPassThrough, $args
  doAssert route.skip.isSome(), $args
  let skip = route.skip.get()
  doAssert skip.reason.kind == psrInvalidFlag, $args
  doAssert skip.reason.flag.isSome(), $args
  doAssert string(skip.reason.flag.get()) == flag, $args

expectQuiet(@["build", "."], false)
expectQuiet(@["build", "--no-cache", "."], false)
expectQuiet(@["build", "-q", "."], true)
expectQuiet(@["build", "--quiet", "."], true)
expectQuiet(@["build", "-q=true", "."], true)
expectQuiet(@["build", "--quiet=True", "."], true)
expectQuiet(@["build", "--quiet=TRUE", "."], true)
expectQuiet(@["build", "-q=false", "."], false)
expectQuiet(@["build", "--quiet=False", "."], false)
expectQuiet(@["build", "--quiet=FALSE", "."], false)
expectQuiet(@["build", "--quiet=false", "-q", "."], true)
expectQuiet(@["build", "-q", "--quiet=false", "."], false)

expectInvalidBool(@["build", "--quiet=tRuE", "."], "--quiet")
expectInvalidBool(@["build", "--quiet=fAlSe", "."], "--quiet")
expectInvalidBool(@["build", "--quiet=t", "."], "--quiet")
expectInvalidBool(@["build", "--quiet=0", "."], "--quiet")
expectInvalidBool(@["build", "--layers=tRuE", "."], "--layers")
expectInvalidBool(@["build", "--layers=fAlSe", "."], "--layers")
expectInvalidBool(@["build", "--layers=t", "."], "--layers")
expectInvalidBool(@["build", "--layers=1", "."], "--layers")
