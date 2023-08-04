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
       nimutils/logging, con4m, c4autoconf, unicode
export os, json, options, tables, strutils, streams, sugar, nimutils, logging,
       con4m, c4autoconf

type
  ChalkDict*    = OrderedTableRef[string, Box]

  ResourceType* = enum
    ResourceFile, ResourceImage, ResourceContainer, ResourcePid

  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    name*:          string      ## The name to use for the artifact.
    cachedHash*:    string      ## Cached 'ending' hash
    cachedPreHash*: string      ## Cached 'unchalked' hash
    collectedData*: ChalkDict   ## What we're adding during insertion.
    extract*:       ChalkDict   ## What we extracted, or nil if no extract.
    opFailed*:      bool
    marked*:        bool
    embeds*:        seq[ChalkObj]
    err*:           seq[string] ## Runtime logs for chalking are filtered
                                ## based on the "chalk log level". They
                                ## end up here, until the end of chalking
                                ## where, they get added to ERR_INFO, if
                                ## any.  To disable, simply set the chalk
                                ## log level to 'none'.
    cache*:         RootRef     ## Generic pointer a codec can use to
                                ## store any state it might want to stash.
    myCodec*:       Codec
    forceIgnore*:   bool        ## If the system decides the codec shouldn't
                                ## process this, set this bool.
    pid*:           Option[Pid] ## If an exec() or eval() and we know
                                ## the pid, this will be set.
    stream*:        FileStream  ## Plugins by default use file streams; we
    startOffset*:   int         ## keep state fields for that to bridge between
    endOffset*:     int         ## extract and write. If the plugin needs to do
                                ## something else, use the cache field
                                ## below, instead.
    fsRef*:         string      ## Reference for this artifact on a fs
    tagRef*:        string      ## Tag reference if this is a docker image
    imageId*:       string      ## Image ID if this is a docker image
    containerId*:   string      ## Container ID if this is a container
    resourceType*:  set[ResourceType]

  Plugin* = ref object of RootObj
    name*:       string
    configInfo*: PluginSpec

  Codec* = ref object of Plugin
    searchPath*: seq[string]

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*: Option[ChalkObj]
    allChalks*:          seq[ChalkObj]
    unmarked*:           seq[string]
    report*:             Box

type
  DockerDirective* = ref object
    name*:       string
    rawArg*:     string
    escapeChar*: Option[Rune]

  DockerCommand* = ref object
    name*:   string
    rawArg*: string
    continuationLines*: seq[int]  # line 's we continue onto.
    errors*: seq[string]

  VarSub* = ref object
    brace*:   bool
    name*:    string
    startix*: int
    endix*:   int
    default*: Option[LineToken]
    error*:   string
    plus*:    bool
    minus*:   bool  #
  LineTokenType* = enum ltOther, ltWord, ltQuoted, ltSpace

  LineToken* = ref object
    # Line tokens with variable substitutions can be a nested tree,
    # because variable substitutions can, when providing default values,
    # have their own substitutions (which can have their own substitutions...)
    #
    # To construct the post-eval string, combine the contents array, with
    # each 'joiner' being a variable substitution operation.
    #
    # The individual pieces in the 'contents' field will be de-quoted
    # already, with escapes processed.
    startix*:    int
    endix*:      int
    kind*:       LineTokenType
    contents*:   seq[string]
    varSubs*:    seq[VarSub]
    quoteType*:  Option[Rune]
    usedEscape*: bool
    error*:      string

  DfFlag* = ref object
    name*:    string
    valid*:   bool
    argtoks*: seq[LineToken]

  TopLevelTokenType* = enum tltComment, tltWhiteSpace, tltCommand, tltDirective
  TopLevelToken* = ref object
    startLine*: int # 0-indexed
    errors*:    seq[string]
    case kind*: TopLevelTokenType
    of tltCommand:
      cmd*: DockerCommand
    of tltDirective:
      directive*: DockerDirective
    else: discard
  CmdParseType* = enum cpFrom, cpUnknown

  DockerParse* = ref object
    currentEscape*:      Rune
    stream*:             Stream
    expectContinuation*: bool
    seenRun*:            bool
    curLine*:            int
    directives*:         OrderedTable[string, DockerDirective]
    cachedCommand*:      DockerCommand
    args*:               Table[string, string]  # Name to default value
    envs*:               Table[string, string]
    commands*:           seq[DockerCommand]
    sourceLines*:        seq[string] # The unparsed input text
    tokens*:             seq[TopLevelToken]
    errors*:             seq[string] # Not the only place errors live for now.
    inArgs*:             Table[string, string]

  InfoBase* = ref object of RootRef
    error*:    string
    stopHere*: bool

  FromInfo* = ref object of InfoBase
    flags*:  seq[DfFlag]
    image*:  Option[LineToken]
    tag*:    Option[LineToken]
    digest*: Option[LineToken]
    asArg*:  Option[LineToken]

  ShellInfo* = ref object of InfoBase
    json*:         JsonNode

  CmdInfo* = ref object of InfoBase
    raw*:          string
    json*:         JsonNode
    str*:          string

  EntryPointInfo* = ref object of InfoBase
    raw*:          string
    json*:         JsonNode
    str*:          string

  OnBuildInfo* = ref object of InfoBase
    rawContents*:  string

  AddInfo* = ref object of InfoBase
    flags*:  seq[DfFlag]
    rawSrc*: seq[string]
    rawDst*: string

  CopyInfo* = ref object of InfoBase
    flags*:  seq[DfFlag]
    rawSrc*: seq[string]
    rawDst*: string

  LabelInfo* = ref object of InfoBase
    labels*: OrderedTable[string, string]

  DockerFileSection* = ref object
    image*:       string
    alias*:       string
    entryPoint*:  EntryPointInfo
    cmd*:         CmdInfo
    shell*:       ShellInfo

  DockerInvocation* = ref object
    dockerExe*:         string
    opChalkObj*:        ChalkObj
    originalArgs*:      seq[string]
    cmd*:               string
    processedArgs*:     seq[string]
    flags*:             OrderedTable[string, FlagSpec]
    foundLabels*:       OrderedTableRef[string, string]
    foundTags*:         seq[string]
    ourTag*:            string
    prefTag*:           string
    passedImage*:       string
    buildArgs*:         Table[string, string]
    foundFileArg*:      string
    dockerfileLoc*:     string
    inDockerFile*:      string
    foundPlatform*:     string
    foundContext*:      string
    otherContexts*:     OrderedTableRef[string, string]
    errs*:              seq[string]
    cmdBuild*:          bool
    cmdPush*:           bool
    privs*:             seq[string]
    targetBuildStage*:  string
    pushAllTags*:       bool
    embededMarks*:      Box
    newCmdLine*:        seq[string] # Rewritten command line
    fileParseCtx*:      DockerParse
    dfCommands*:        seq[InfoBase]
    dfSections*:        seq[DockerFileSection]
    dfSectionAliases*:  OrderedTable[string, DockerFileSection]
    addedInstructions*: seq[string]
    tmpFiles*:          seq[string]


# Compile-time only helper for generating one of the consts below.
proc commentC4mCode(s: string): string =
  let lines = s.split("\n")
  result    = ""
  for line in lines: result &= "# " & line & "\n"

  # Some string constants, mostly used in multiple places.
const
  magicUTF8*          = "dadfedabbadabbed"
  emptyMark*          = "{ \"MAGIC\" : \"" & magicUTF8 & "\" }"
  implName*           = "chalk-reference"
  tmpFilePrefix*      = "chalk-"
  tmpFileSuffix*      = "-file.tmp"
  chalkSpecName*      = "configs/chalk.c42spec"
  getoptConfName*     = "configs/getopts.c4m"
  baseConfName*       = "configs/base_*.c4m"
  signConfName*       = "configs/signconfig.c4m"
  sbomConfName*       = "configs/sbomconfig.c4m"
  sastConfName*       = "configs/sastconfig.c4m"
  ioConfName*         = "configs/ioconfig.c4m"
  dockerConfName*     = "configs/dockercmd.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  chalkC42Spec*       = staticRead(chalkSpecName)
  getoptConfig*       = staticRead(getoptConfName)
  baseConfig*         = staticRead("configs/base_keyspecs.c4m") &
                        staticRead("configs/base_plugins.c4m") &
                        staticRead("configs/base_sinks.c4m") &
                        staticRead("configs/base_profiles.c4m") &
                        staticRead("configs/base_outconf.c4m") &
                        staticRead("configs/base_sinkconfs.c4m")
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


when hostOs == "macosx":
  proc getMyAppPath*(): string =
    let name = betterGetAppFileName()

    if "_CHALK" notin name:
      return name
    let parts = name.split("_CHALK")[0 .. ^1]

    for item in parts:
      if len(item) < 3:
        return name
      case item[0 ..< 3]
      of "HM_":
        result &= "#"
      of "SP_":
        result &= " "
      of "SL_":
        result &= "/"
      else:
        return name
      if len(item) > 3:
        result &= item[3 .. ^1]
    echo "getMyAppPath() = ", result
else:
  template getMyAppPath*(): string = betterGetAppFileName()

template dumpExOnDebug*() =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    let msg = "Handling exception (msg = " & getCurrentExceptionMsg() & ")\n" &
      getCurrentException().getStackTrace()
    publish("debug", msg)

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
