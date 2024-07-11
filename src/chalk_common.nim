##
## Copyright (c) 2023-2024, Crash Override, Inc.
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

import std/[os, json, streams, tables, options, strutils, sugar, posix,
            unicode, re]
import pkg/[nimutils, nimutils/logging, nimutils/managedtmp, con4m]
export os, json, options, tables, strutils, streams, sugar, nimutils, logging,
       managedtmp, con4m

type
  ChalkDict*    = OrderedTableRef[string, Box]

  ResourceType* = enum
    ResourceFile, ResourceImage, ResourceContainer, ResourcePid

  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    name*:          string           ## The name to use for the artifact in errors.
    cachedHash*:    string           ## Cached 'ending' hash
    cachedPreHash*: string           ## Cached 'unchalked' hash
    collectedData*: ChalkDict        ## What we're adding during insertion.
    extract*:       ChalkDict        ## What we extracted, or nil if no extract.
    cachedMark*:    string           ## Cached chalk mark.
    commentPrefix*: string           ## For scripting languages only, the comment
                                     ## prefix we use when adding / rming marks
    detectedLang*:  string           ## Currently only used in codecSource.
    opFailed*:      bool
    marked*:        bool
    embeds*:        seq[ChalkObj]
    err*:           seq[string]      ## Runtime logs for chalking are filtered
                                     ## based on the "chalk log level". They
                                     ## end up here, until the end of chalking
                                     ## where, they get added to ERR_INFO, if
                                     ## any.  To disable, simply set the chalk
                                     ## log level to 'none'.
    cache*:         RootRef          ## Generic pointer a codec can use to
                                     ## store any state it might want to stash.
    myCodec*:       Plugin
    forceIgnore*:   bool             ## If the system decides the codec shouldn't
                                     ## process this, set this bool.
    pid*:           Option[Pid]      ## If an exec() or eval() and we know
                                     ## the pid, this will be set.
    startOffset*:   int              ## Plugins by default use file streams; we
    endOffset*:     int              ## keep state fields for that to bridge between
                                     ## extract and write. If the plugin needs to do
                                     ## something else, use the cache field
                                     ## below, instead.
    fsRef*:         string           ## Reference for this artifact on a fs
    platform*:      DockerPlatform   ## platform
    images*:        seq[DockerImage] ## all images where image was tagged/pushed
    imageId*:       string           ## Image ID if this is a docker image
    imageDigest*:   string           ## Image digest in the repo.
    listDigest*:    string           ## Manifest list digest in the repo.
    containerId*:   string           ## Container ID if this is a container
    noCosign*:      bool             ## When we know image is not in registry. skips validation
    signed*:        bool             ## True on the insert path once signed,
                                     ## and once we've seen an attestation otherwise
    inspected*:     bool             ## True for images once inspected; we don't
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
    enabled*:                  bool
    configInfo*:               AttrScope
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

  AttestationKey* = ref object
    password*:   string
    publicKey*:  string
    privateKey*: string
    tmpPath*:    string

  AttestationKeyProvider* = ref object of RootRef
    name*:             string
    init*:             proc (self: AttestationKeyProvider)
    generateKey*:      proc (self: AttestationKeyProvider): AttestationKey
    retrieveKey*:      proc (self: AttestationKeyProvider): AttestationKey
    retrievePassword*: proc (self: AttestationKeyProvider, key: AttestationKey): string

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*:       Option[ChalkObj]
    allChalks*:                seq[ChalkObj]
    unmarked*:                 seq[string]
    report*:                   Box
    args*:                     seq[string]
    contextDirectories*:       seq[string]

  ArtifactIterationInfo* = ref object
    filePaths*:       seq[string]
    otherPaths*:      seq[string]
    fileExclusions*:  seq[string]
    skips*:           seq[Regex]
    chalks*:          seq[ChalkObj]
    recurse*:         bool

  DockerStatement* = ref object of RootRef
    startLine*:  int
    endLine*:    int
    name*:       string
    rawArg*:     string

  DockerDirective* = ref object of DockerStatement
    escapeChar*: Option[Rune]

  DockerCommand* = ref object of DockerStatement
    continuationLines*: seq[int]  # line 's we continue onto.
    errors*:            seq[string]

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
    line*:       int
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

  DockerPlatform* = ref object
    os*:           string
    architecture*: string
    variant*:      string

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
    error*:     string
    startLine*: int
    endLine*:   int

  FromInfo* = ref object of InfoBase
    flags*:  Table[string, DfFlag]
    repo*:   Option[LineToken]
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
    raw*:  string

  AddInfo* = ref object of InfoBase
    flags*:  Table[string, DfFlag]
    rawSrc*: seq[string]
    rawDst*: string

  CopyInfo* = ref object of InfoBase
    flags*:  Table[string, DfFlag]
    rawSrc*: seq[string]
    rawDst*: string

  UserInfo* = ref object of InfoBase
    str*: string

  LabelInfo* = ref object of InfoBase
    labels*: OrderedTable[string, string]

  DockerFileSection* = ref object
    startLine*:   int
    endLine*:     int
    platform*:    DockerPlatform
    image*:       DockerImage
    alias*:       string
    entrypoint*:  EntryPointInfo
    cmd*:         CmdInfo
    shell*:       ShellInfo
    lastUser*:    UserInfo

  DockerEntrypoint* = tuple
    entrypoint: EntryPointInfo
    cmd:        CmdInfo
    shell:      ShellInfo

  DockerImage* = tuple
    repo:   string
    tag:    string
    digest: string

  GitHeadType* = enum
    commit, branch, tag, other

  GitHead* = ref object
    gitRef*:       string
    gitType*:      GitHeadType
    commitId*:     string
    # first matching branch for commit ref, if any
    branches*:     seq[string]
    tags*:         seq[string]
    refs*:         seq[string]

  DigestedJson* = ref object
    json*:   JsonNode
    digest*: string
    size*:   int

  DockerManifestType* = enum
    list, image, config, layer

  DockerManifest* = ref object
    name*:             DockerImage # where manifest was fetched from
    otherNames*:       seq[DockerImage]
    digest*:           string
    mediaType*:        string
    size*:             int
    json*:             JsonNode
    isFetched*:        bool
    case kind*:        DockerManifestType
    of list:
      manifests*:      seq[DockerManifest]
    of image:
      list*:           DockerManifest # can be null if there is manifest list
      platform*:       DockerPlatform
      config*:         DockerManifest
      layers*:         seq[DockerManifest]
    of config:
      image*:          DockerManifest
      configPlatform*: DockerPlatform
    of layer:
      discard

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

  DockerCmd* = enum
    build, push, other

  DockerInvocation* = ref object
    chalkId*:                 string # shared between multi-platform builds

    # basic attributes required for docker fail safe
    originalArgs*:            seq[string]
    originalStdIn*:           string # if we ever read stdin we backup here for fail-through
    processedArgs*:           seq[string]
    processedFlags*:          OrderedTable[string, FlagSpec]
    newCmdLine*:              seq[string] # Rewritten command line
    newStdIn*:                string

    cmdName*:                 string
    case cmd*:                DockerCmd

    of DockerCmd.build:
      foundBuildx*:           bool # whether using "docker buildx build" or "docker build"
      foundIidFile*:          string
      foundMetadataFile*:     string
      foundFileArg*:          string
      foundContext*:          string
      foundLabels*:           OrderedTableRef[string, string]
      foundTags*:             seq[DockerImage]
      foundBuildArgs*:        TableRef[string, string]
      foundPlatforms*:        seq[DockerPlatform]
      foundExtraContexts*:    OrderedTableRef[string, string]
      foundSecrets*:          TableRef[string, DockerSecret]
      foundTarget*:           string
      foundBuilder*:          string

      gitContext*:            DockerGitContext

      iidFilePath*:           string
      iidFile*:               string
      metadataFilePath*:      string
      metadataFile*:          JsonNode
      dockerFileLoc*:         string # can be :stdin:
      inDockerFile*:          string
      addedPlatform*:         OrderedTableRef[string, seq[string]]
      addedInstructions*:     seq[string]

      # parsed dockerfile
      dfSections*:            seq[DockerFileSection]
      dfSectionAliases*:      OrderedTable[string, DockerFileSection]

    of DockerCmd.push:
      foundImage*:            string
      foundAllTags*:          bool

    else:
      discard

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
  ioConfName*         = "configs/ioconfig.c4m"
  attestConfName*     = "configs/attestation.c4m"
  coConfName*         = "configs/crashoverride.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  embeddedConfName*   = "[embedded config]"
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
  ioConfig*           = staticRead(ioConfName)
  defaultConfig*      = staticRead(defCfgFname) #& commentC4mCode(ioConfig)
  attestConfig*       = staticRead(attestConfName)
  coConfig*           = staticRead(coConfName)
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
  con4mRuntime*:          ConfigStack
  commandName*:           string
  gitExeLocation*:        string = ""
  sshKeyscanExeLocation*: string = ""
  dockerInvocation*:      DockerInvocation

template dumpExOnDebug*() =
  if getChalkScope() != nil and get[bool](getChalkScope(), "chalk_debug"):
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
