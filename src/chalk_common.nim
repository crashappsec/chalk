##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This file contains common type definitions and a few helper
## functions that couldn't easily live in a more naturally named
## module due to cross-module dependency issues.
##
## This file should never import other chalk modules; it's at the root
## of the dependency tree.

import os, json, streams, tables, options, strutils, nimutils, sugar, posix,
       nimutils/logging, nimutils/managedtmp, con4m, c4autoconf, unicode, re
export os, json, options, tables, strutils, streams, sugar, nimutils, logging,
       managedtmp, con4m, c4autoconf

type
  ChalkDict*    = OrderedTableRef[string, Box]

  ResourceType* = enum
    ResourceFile, ResourceImage, ResourceContainer, ResourcePid

  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    name*:          string      ## The name to use for the artifact in errors.
    cachedHash*:    string      ## Cached 'ending' hash
    cachedPreHash*: string      ## Cached 'unchalked' hash
    collectedData*: ChalkDict   ## What we're adding during insertion.
    extract*:       ChalkDict   ## What we extracted, or nil if no extract.
    cachedMark*:    string      ## Cached chalk mark.
    commentPrefix*: string      ## For scripting languages only, the comment
                                ## prefix we use when adding / rming marks
    detectedLang*:  string      ## Currently only used in codecSource.
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
    myCodec*:       Plugin
    forceIgnore*:   bool        ## If the system decides the codec shouldn't
                                ## process this, set this bool.
    pid*:           Option[Pid] ## If an exec() or eval() and we know
                                ## the pid, this will be set.
    stream*:        FileStream  ## Plugins by default use file streams; we
    startOffset*:   int         ## keep state fields for that to bridge between
    endOffset*:     int         ## extract and write. If the plugin needs to do
                                ## something else, use the cache field
                                ## below, instead.
    streamRefCt*:   int         ## Ref count for recursive acquires.
    fsRef*:         string      ## Reference for this artifact on a fs
    userRef*:       string      ## Reference the user gave for the artifact.
    repo*:          string      ## The docker repo.
    tag*:           string      ## The image tag, if any.
    shortId*:       string      ## The short hash ID of an image.
    imageId*:       string      ## Image ID if this is a docker image
    repoHash*:      string      ## Image ID in the repo.
    containerId*:   string      ## Container ID if this is a container
    signed*:        bool        ## True on the insert path once signed,
                                ## and once we've seen an attestation otherwise
    inspected*:     bool        ## True for images once inspected; we don't
                                ## need to inspect twice when we build + push.
    resourceType*:  set[ResourceType]

  ChalkTimeHostCb*     = proc (a: Plugin): ChalkDict {.cdecl.}
  ChalkTimeArtifactCb* = proc (a: Plugin, b: ChalkObj): ChalkDict {.cdecl.}
  RunTimeArtifactCb*   = proc (a: Plugin, b: ChalkObj, c: bool):
                             ChalkDict {.cdecl.}
  RunTimeHostCb*       = proc (a: Plugin, b: seq[ChalkObj]): ChalkDict {.cdecl.}
  ScanCb*              = proc (a: Plugin, b: string): Option[ChalkObj] {.cdecl.}
  UnchalkedHashCb*     = proc (a: Plugin, b: ChalkObj): Option[string] {.cdecl.}
  EndingHashCb*        = proc (a: Plugin, b: ChalkObj): Option[string] {.cdecl.}
  ChalkIdCb*           = proc (a: Plugin, b: ChalkObj): string {.cdecl.}
  HandleWriteCb*       = proc (a: Plugin, b: ChalkObj,
                               c: Option[string]) {.cdecl.}
  Plugin* = ref object
    name*:                     string
    configInfo*:               PluginSpec
    getChalkTimeHostInfo*:     ChalkTimeHostCb
    getChalkTimeArtifactInfo*: ChalkTimeArtifactCb
    getRunTimeArtifactInfo*:   RunTimeArtifactCb
    getRunTimeHostInfo*:       RunTimeHostCb

    # Codec-only bits
    nativeObjPlatforms*:       seq[string]
    scan*:                     ScanCb
    getUnchalkedHash*:         UnchalkedHashCb
    getEndingHash*:            EndingHashCb
    getChalkId*:               ChalkIdCb
    handleWrite*:              HandleWriteCb
    # Currently, this is used by procfs on Linux.
    internalState*:            RootRef
    # This is only used when using the default script chalking.
    commentStart*:             string

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*:       Option[ChalkObj]
    allChalks*:                seq[ChalkObj]
    unmarked*:                 seq[string]
    report*:                   Box
    args*:                     seq[string]

  ArtifactIterationInfo* = ref object
    filePaths*:       seq[string]
    otherPaths*:      seq[string]
    fileExclusions*:  seq[string]
    skips*:           seq[Regex]
    chalks*:          seq[ChalkObj]
    recurse*:         bool

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

  DfUserInfo* = ref object of InfoBase
    str*: string

  LabelInfo* = ref object of InfoBase
    labels*: OrderedTable[string, string]

  DockerFileSection* = ref object
    image*:       string
    alias*:       string
    entryPoint*:  EntryPointInfo
    cmd*:         CmdInfo
    shell*:       ShellInfo
    lastUser*:    DfUserInfo

  GitHeadType* = enum
    commit, branch, tag

  GitHead* = ref object
    gitRef*:       string
    gitType*:      GitHeadType
    commitId*:     string
    # first matching branch for commit ref, if any
    branches*:     seq[string]
    tags*:         seq[string]

  DockerGitContext* = ref object
    context*:      string
    # https://docs.docker.com/engine/reference/commandline/build/
    # context is a combination of remote url + head + subdir within the context
    remoteUrl*:    string
    head*:         GitHead
    subdir*:       string
    authToken*:    string
    authHeader*:   string
    tmpGitDir*:    string
    tmpWorkTree*:  string
    tmpKnownHost*: string

  DockerSecret* = ref object
    id*:   string
    src*:  string

  DockerInvocation* = ref object
    dockerExe*:         string
    opChalkObj*:        ChalkObj
    chalkId*:           string # shared between multi-platform builds
    originalArgs*:      seq[string]
    cmd*:               string
    processedArgs*:     seq[string]
    flags*:             OrderedTable[string, FlagSpec]
    foundLabels*:       OrderedTableRef[string, string]
    foundTags*:         seq[string]
    ourTag*:            string # This is what chalk added.
    prefTag*:           string # This is what the user gave via -t or similar.
    passedImage*:       string
    buildArgs*:         Table[string, string]
    foundFileArg*:      string
    dockerfileLoc*:     string
    inDockerFile*:      string
    foundPlatform*:     string
    foundContext*:      string
    otherContexts*:     OrderedTableRef[string, string]
    gitContext*:        DockerGitContext
    secrets*:           Table[string, DockerSecret]
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
    dfPassOnStdin*:     bool
    addedInstructions*: seq[string]

  ValidateResult* = enum
    vOk, vSignedOk, vBadMd, vNoCosign, vBadSig, vNoHash, vNoPk


# # Compile-time only helper for generating one of the consts below.
# proc commentC4mCode(s: string): string =
#   let lines = s.split("\n")
#   result    = ""
#   for line in lines: result &= "# " & line & "\n"

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
  sbomConfName*       = "configs/sbomconfig.c4m"
  sastConfName*       = "configs/sastconfig.c4m"
  techStackConfName*  = "configs/techstackconfig.c4m"
  linguistConfName*  = "configs/linguist.c4m"
  ioConfName*         = "configs/ioconfig.c4m"
  attestConfName*     = "configs/attestation.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  chalkC42Spec*       = staticRead(chalkSpecName)
  getoptConfig*       = staticRead(getoptConfName)
  baseConfig*         = staticRead("configs/base_init.c4m") &
                        staticRead("configs/base_keyspecs.c4m") &
                        staticRead("configs/base_plugins.c4m") &
                        staticRead("configs/base_sinks.c4m") &
                        staticRead("configs/base_auths.c4m") &
                        staticRead("configs/base_chalk_templates.c4m") &
                        staticRead("configs/base_report_templates.c4m") &
                        staticRead("configs/base_outconf.c4m") &
                        staticRead("configs/base_sinkconfs.c4m") &
                        staticRead("configs/dockercmd.c4m")
  sbomConfig*         = staticRead(sbomConfName)
  sastConfig*         = staticRead(sastConfName)
  techStackConfig*    = staticRead(techStackConfName)
  linguistConfig*     = staticRead(linguistConfName)
  ioConfig*           = staticRead(ioConfName)
  defaultConfig*      = staticRead(defCfgFname) #& commentC4mCode(ioConfig)
  attestConfig*       = staticRead(attestConfName)
  versionStr*         = staticexec("cat ../*.nimble | grep ^version")
  commitID*           = staticexec("git rev-parse HEAD")
  archStr*            = staticexec("uname -m")
  osStr*              = staticexec("uname -o")

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
  hostInfo*               = ChalkDict()
  subscribedKeys*         = Table[string, bool]()
  systemErrors*           = seq[string](@[])
  selfChalk*              = ChalkObj(nil)
  selfID*                 = none(string)
  canSelfInject*          = true
  doingTestRun*           = false
  nativeCodecsOnly*       = false
  passedHelpFlag*         = false
  chalkConfig*:           ChalkConfig
  con4mRuntime*:          ConfigStack
  commandName*:           string
  dockerExeLocation*:     string = ""
  gitExeLocation*:        string = ""
  sshKeyscanExeLocation*: string = ""
  cachedChalkStreams*:    seq[ChalkObj]

template dumpExOnDebug*() =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    let
      msg = "" # "Handling exception (msg = " & getCurrentExceptionMsg() & ")\n"
      tb  = "Traceback (most recent call last)\n" &
             getCurrentException().getStackTrace()
      ii  = default(InstInfo)

    publish("debug", formatCompilerError(msg, nil, tb, ii))

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
