## This file contains common type definitions and a few helper
## functions that couldn't easily live in a more naturally named
## module due to cross-module dependency issues.
##
## This file should never import other chalk modules; it's at the root
## of the dependency tree.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, json, streams, tables, options, strutils, nimutils, sugar, posix,
       nimutils/logging, con4m, c4autoconf
export os, json, options, tables, strutils, streams, sugar, nimutils, logging,
       con4m, c4autoconf

type
  ChalkDict* = OrderedTableRef[string, Box]
  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    fullpath*:      string      ## The path to the artifact.
    cachedHash*:    string      ## Cached 'ending' hash
    cachedPreHash*: string      ## Cached 'unchalked' hash
    collectedData*: ChalkDict   ## What we're adding during insertion.
    extract*:       ChalkDict   ## What we extracted, or nil if no extract.
    opFailed*:      bool
    marked*:        bool
    embeds*:        seq[ChalkObj]
    stream*:        FileStream  # Plugins by default use file streams; we
    startOffset*:   int         # keep state fields for that to bridge between
    endOffset*:     int         # extract and write. If the plugin needs to do
                                # something else, use the cache field
                                # below, instead.
    err*:           seq[string] ## runtime logs for chalking are filtered
                                ## based on the "chalk log level". They
                                ## end up here, until the end of chalking
                                ## where, they get added to ERR_INFO, if
                                ## any.  To disable, simply set the chalk
                                ## log level to 'none'.
    cache*:         RootRef     ## Generic pointer a codec can use to
                                ## store any state it might want to stash.
    myCodec*:       Codec
    auxPaths*:      seq[string] ## File-system references for this
                                ## artifact, when the fullpath isn't a
                                ## file system reference.  For
                                ## example, in a docker container,
                                ## this can contain the context
                                ## directory and the docker file.
    forceIgnore*:   bool        ## If the system decides the codec shouldn't
                                ## process this, set this bool.
    noResolvePath*: bool        ## True when the system plugin should not
                                ## call resolvePath when setting the
                                ## artifact path.
    pid*:           Option[Pid] ## If an exec() or eval() and we know
                                ## the pid, this will be set.

  Plugin* = ref object of RootObj
    name*:       string
    configInfo*: PluginSpec

  Codec* = ref object of Plugin
    searchPath*: seq[string]
    runtime*:    bool   # Set to true when we run via exec since codecs
                        # might have different visibility.

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*: Option[ChalkObj]
    allChalks*:          seq[ChalkObj]
    unmarked*:           seq[string]
    report*:             Box
    postprocessor*:      (CollectionCtx) -> void

# Compile-time only helper for generating one of the consts below.
proc commentC4mCode(s: string): string =
  let lines = s.split("\n")
  result    = ""
  for line in lines: result &= "# " & line & "\n"

  # Some string constants, mostly used in multiple places.
const
  magicUTF8*          = "dadfedabbadabbed"
  emptyMark*          = "{ \"MAGIC\" : \"" & magicUTF8 & "\" }"
  tmpFilePrefix*      = "chalk-"
  tmpFileSuffix*      = "-file.tmp"
  chalkSpecName*      = "configs/chalk.c42spec"
  getoptConfName*     = "configs/getopts.c4m"
  baseConfName*       = "configs/baseconfig.c4m"
  signConfName*       = "configs/signconfig.c4m"
  sbomConfName*       = "configs/sbomconfig.c4m"
  sastConfName*       = "configs/sastconfig.c4m"
  ioConfName*         = "configs/ioconfig.c4m"
  dockerConfName*     = "configs/dockercmd.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  chalkC42Spec*       = staticRead(chalkSpecName)
  getoptConfig*       = staticRead(getoptConfName)
  baseConfig*         = staticRead(baseConfName)
  signConfig*         = staticRead(signConfName)
  sbomConfig*         = staticRead(sbomConfName)
  sastConfig*         = staticRead(sastConfName)
  ioConfig*           = staticRead(ioConfName)
  dockerConfig*       = staticRead(dockerConfName)
  defaultConfig*      = staticRead(defCfgFname) & commentC4mCode(ioConfig)
  versionStr*         = staticexec("cat ../*.nimble | grep ^version")
  commitID*           = staticexec("git rev-parse HEAD")
  archStr*            = staticexec("uname -m")
  osStr*              = staticexec("uname -o")
  #% INTERNAL
  entryPtTemplateLoc* = "configs/entrypoint.c4m"
  entryPtTemplate*    = staticRead(entryPtTemplateLoc)
  #% END
  # Make sure that ARTIFACT_TYPE fields are consistently named. I'd love
  # these to be const, but nim doesn't seem to be able to handle that :(
let
  artTypeElf*             = pack("ELF")
  artTypeShebang*         = pack("Unix Script")
  artTypeZip*             = pack("ZIP")
  artTypeJAR*             = pack("JAR")
  artTypeWAR*             = pack("WAR")
  artTypeEAR*             = pack("EAR")
  artTypeDockerImage*     = pack("Docker Image")
  artTypeDockerContainer* = pack("Docker Container")
  artTypePy*              = pack("Python")
  artTypePyc*             = pack("Python Bytecode")
  artTypeMachO*           = pack("Mach-O executable")

var
  hostInfo*           = ChalkDict()
  subscribedKeys*     = Table[string, bool]()
  systemErrors*       = seq[string](@[])
  selfChalk*          = ChalkObj(nil)
  selfID*             = Option[string](none(string))
  canSelfInject*      = true
  doingTestRun*       = false
  chalkConfig*:       ChalkConfig
  con4mRuntime*:      ConfigStack
  commandName*:       string
  currentOutputCfg*:  OutputConfig


when hostOs == "macosx":
  {.emit: """
#include <unistd.h>
#include <libproc.h>

   char *c_get_app_fname(char *buf) {
     proc_pidpath(getpid(), buf, PROC_PIDPATHINFO_MAXSIZE); // 4096
     return buf;
   }
   """.}

  proc cGetAppFilename(x: cstring): cstring {.importc: "c_get_app_fname".}

  proc betterGetAppFileName(): string =
    var x: array[4096, byte]

    return $(cGetAppFilename(cast[cstring](addr x[0])))

elif hostOs == "linux":
  {.emit: """
#include <unistd.h>

   char *c_get_app_fname(char *buf) {
   char proc_path[128];
   snprintf(proc_path, 128, "/proc/%d/exe", getpid());
   readlink(proc_path, buf, 4096);
   return buf;
   }
   """.}

  proc cGetAppFilename(x: cstring): cstring {.importc: "c_get_app_fname".}

  proc betterGetAppFileName(): string =
    var x: array[4096, byte]

    return $(cGetAppFilename(cast[cstring](addr x[0])))
else:
  template betterGetAppFileName(): string = getAppFileName()


template getMyAppPath*(): string =
  when hostOs == "macosx":
    if chalkConfig == nil:
      betterGetAppFileName()
    else:
      chalkConfig.getSelfLocation().getOrElse(betterGetAppFileName())
  else:
    betterGetAppFileName()

template dumpExOnDebug*() =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    publish("debug", getCurrentException().getStackTrace())

proc getBaseCommandName*(): string =
  if '.' in commandName:
    result = commandName.split('.')[0]
  else:
    result = commandName

template formatTitle*(text: string): string =
  ## Used by both help and defaults command.
  let
    titleCode = toAnsiCode(@[acFont4, acBRed])
    endCode   = toAnsiCode(@[acReset])

  titleCode & text & endCode & "\n"
