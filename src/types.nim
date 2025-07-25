##
## Copyright (c) 2023-2025, Crash Override, Inc.
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

import std/[
  options,
  posix,
  re,
  streams,
  sugar,
  unicode,
  uri,
]
import pkg/[
  nimutils,
  nimutils/logging,
  con4m,
]
import "."/[
  con4mwrap,
  utils/chalkdict,
  utils/json,
  utils/sets,
  utils/strings,
  utils/tables,
]

export chalkdict # ChalkDict
export con4mwrap # con4m accessors/etc
export logging   # error()/trace()/etc
export nimutils  # Box
export options   # .get()/etc for accessing chalk Option() vars
export streams   # Stream()
export strings   # string split/etc
export sugar     # easier calling functions
export tables

type
  ObjectsDict*  = OrderedTableRef[string, OrderedTableRef[string, ObjectStoreRef]]

  ResourceType* = enum
    ResourceFile, ResourceImage, ResourceContainer, ResourcePid, ResourceCert

  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    name*:                  string           ## The name to use for the artifact in errors.
    cachedUnchalkedHash*:   string           ## Cached 'unchalked' hash (without any chalkmarks)
    cachedPrechalkingHash*: string           ## Cached pre-chalking hash (with previous chalkmarks but without new chalkmark)
    cachedEndingHash*:      string           ## Cached 'ending' hash (with new chalkmark)
    collectedData*:         ChalkDict        ## What we're adding during insertion.
    objectsData*:           ObjectsDict      ## per object store and key object ref
    extract*:               ChalkDict        ## What we extracted, or nil if no extract.
    cachedMark*:            string           ## Cached chalk mark.
    opFailed*:              bool
    marked*:                bool
    embeds*:                seq[ChalkObj]
    failedKeys*:            ChalkDict
    err*:                   seq[string]      ## Runtime logs for chalking are filtered
                                             ## based on the "chalk log level". They
                                             ## end up here, until the end of chalking
                                             ## where, they get added to ERR_INFO, if
                                             ## any.  To disable, simply set the chalk
                                             ## log level to 'none'.
    cache*:                 RootRef          ## Generic pointer a codec can use to
                                             ## store any state it might want to stash.
    myCodec*:               Plugin
    forceIgnore*:           bool             ## If the system decides the codec shouldn't
                                             ## process this, set this bool.
    pid*:                   Option[Pid]      ## If an exec() or eval() and we know
                                             ## the pid, this will be set.
    startOffset*:           int              ## Plugins by default use file streams; we
    endOffset*:             int              ## keep state fields for that to bridge between
                                             ## extract and write. If the plugin needs to do
                                             ## something else, use the cache field
                                             ## below, instead.
    fsRef*:                 string           ## Reference for this artifact on a fs
    accessed*:              bool             ## Whether artifact was accessed during chalk operation (used only in exec)
    envVarName*:            string           ## env var name from where artifact is found
    platform*:              DockerPlatform   ## platform
    baseChalk*:             ChalkObj
    repos*:                 OrderedTableRef[string, DockerImageRepo] ## all images where image was tagged/pushed
    imageId*:               string           ## Image ID if this is a docker image
    containerId*:           string           ## Container ID if this is a container
    noAttestation*:         bool             ## Whether to skip attestation for chalkmark
    noCosign*:              bool             ## When we know image is not in registry. skips validation
    signed*:                bool             ## True on the insert path once signed,
                                             ## and once we've seen an attestation otherwise
    resourceType*:          set[ResourceType]

  PluginClearCb*       = proc (a: Plugin) {.cdecl.}
  ChalkTimeHostCb*     = proc (a: Plugin): ChalkDict {.cdecl.}
  ChalkTimeArtifactCb* = proc (a: Plugin, b: ChalkObj): ChalkDict {.cdecl.}
  RunTimeArtifactCb*   = proc (a: Plugin, b: ChalkObj, c: bool): ChalkDict {.cdecl.}
  RunTimeHostCb*       = proc (a: Plugin, b: seq[ChalkObj]): ChalkDict {.cdecl.}
  ScanCb*              = proc (a: Plugin, b: string): Option[ChalkObj] {.cdecl.}
  SearchCb*            = proc (a: Plugin, b: string): seq[ChalkObj] {.cdecl.}
  SearchEnvVarCb*      = proc (a: Plugin, b: string, c: string): seq[ChalkObj] {.cdecl.}
  UnchalkedHashCb*     = proc (a: Plugin, b: ChalkObj): Option[string] {.cdecl.}
  PrechalkingHashCb*   = proc (a: Plugin, b: ChalkObj): Option[string] {.cdecl.}
  EndingHashCb*        = proc (a: Plugin, b: ChalkObj): Option[string] {.cdecl.}
  ChalkIdCb*           = proc (a: Plugin, b: ChalkObj): string {.cdecl.}
  HandleWriteCb*       = proc (a: Plugin, b: ChalkObj, c: Option[string]) {.cdecl.}

  Plugin* = ref object
    name*:                     string
    enabled*:                  bool
    isSystem*:                 bool
    isCodec*:                  bool
    clearState*:               PluginClearCb
    getChalkTimeHostInfo*:     ChalkTimeHostCb
    getChalkTimeArtifactInfo*: ChalkTimeArtifactCb
    getRunTimeArtifactInfo*:   RunTimeArtifactCb
    getRunTimeHostInfo*:       RunTimeHostCb

    # Codec-only bits
    nativeObjPlatforms*:       seq[string]
    scan*:                     ScanCb
    search*:                   SearchCb
    searchEnvVar*:             SearchEnvVarCb
    getUnchalkedHash*:         UnchalkedHashCb
    getPrechalkingHash*:       PrechalkingHashCb
    getEndingHash*:            EndingHashCb
    getChalkId*:               ChalkIdCb
    handleWrite*:              HandleWriteCb
    # Currently, this is used by procfs on Linux.
    internalState*:            RootRef
    # This is only used when using the default script chalking.
    commentStart*:             string
    resourceTypes*:            set[ResourceType]

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

  ObjectStoreRef* = ref object
    config*: ObjectStoreConfig
    key*:    string
    id*:     string
    digest*: string
    query*:  string

  ObjectStore* = ref object of RootRef
    name*:         string
    init*:         proc (self: ObjectStore, name: string): ObjectStoreConfig
    uri*:          proc (self: ObjectStoreConfig, keyRef: ObjectStoreRef): Uri
    objectExists*: proc (self: ObjectStoreConfig, keyRef: ObjectStoreRef): ObjectStoreRef
    createObject*: proc (self: ObjectStoreConfig, keyRef: ObjectStoreRef, data: string): ObjectStoreRef

  ObjectStoreConfig* = ref object of RootRef
    name*:  string
    store*: ObjectStore

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*:       Option[ChalkObj]
    allChalks*:                seq[ChalkObj]
    allArtifacts*:             seq[ChalkObj]
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
    envVars*:         bool

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
    minus*:   bool

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
    image*:  Option[seq[LineToken]]
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
    frm*:    string
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
    fromInfo*:    FromInfo
    image*:       DockerImage
    foundImage*:  DockerImage
    alias*:       string
    copies*:      seq[CopyInfo]
    entrypoint*:  EntryPointInfo
    cmd*:         CmdInfo
    shell*:       ShellInfo
    lastUser*:    UserInfo
    chalk*:       ChalkObj

  DockerEntrypoint* = tuple
    entrypoint: EntryPointInfo
    cmd:        CmdInfo
    shell:      ShellInfo

  DockerImage* = tuple
    repo:   string
    tag:    string
    digest: string

  DockerImageRepo* = ref object
    repo*:        string
    digests*:     OrderedSet[string]
    listDigests*: OrderedSet[string]
    tags*:        OrderedSet[string]

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

  DigestedJson* = ref object of RootObj
    json*:   JsonNode
    digest*: string
    size*:   int

  DockerDigestedJson* = ref object of DigestedJson
    mediaType*: string
    kind*:      DockerManifestType

  DockerManifestType* = enum
    list, image, config, layer

  DockerManifest* = ref object
    name*:             DockerImage # where manifest was fetched from
    digest*:           string
    mediaType*:        string
    size*:             int
    json*:             JsonNode
    annotations*:      JsonNode
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
      foundAnnotations*:      OrderedTableRef[string, string]
      foundTags*:             seq[DockerImage]
      foundBuildArgs*:        TableRef[string, string]
      foundPlatforms*:        seq[DockerPlatform]
      foundExtraContexts*:    OrderedTableRef[string, string]
      foundSecrets*:          TableRef[string, DockerSecret]
      foundTarget*:           string
      foundBuilder*:          string

      platforms*:             seq[DockerPlatform]
      gitContext*:            DockerGitContext

      iidFilePath*:           string
      iidFile*:               string
      metadataFilePath*:      string
      metadataFile*:          JsonNode
      dockerFileLoc*:         string # can be :stdin:
      vctlDockerFileLoc*:     string # path within version control
      inDockerFile*:          string
      addedPlatform*:         OrderedTableRef[string, seq[string]]
      addedInstructions*:     seq[string]

      # parsed dockerfile
      dfSections*:            seq[DockerFileSection]
      dfSectionAliases*:      OrderedTable[string, DockerFileSection]
      dfDirectives*:          OrderedTableRef[string, string]

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
  chalkSpecName*      = "configs/chalk.c42spec"
  getoptConfName*     = "configs/getopts.c4m"
  baseConfName*       = "configs/base_*.c4m"
  sbomConfName*       = "configs/sbomconfig.c4m"
  sastConfName*       = "configs/sastconfig.c4m"
  secretsConfName*    = "configs/secretscannerconfig.c4m"
  ioConfName*         = "configs/ioconfig.c4m"
  attestConfName*     = "configs/attestation.c4m"
  coConfName*         = "configs/crashoverride.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  embeddedConfName*   = "[embedded config]"
  chalkC42Spec*       = staticRead(chalkSpecName)
  getoptConfig*       = staticRead(getoptConfName)
  baseConfig*         = staticRead("configs/base_init.c4m") &
                        staticRead("configs/base_callbacks.c4m") &
                        staticRead("configs/base_keyspecs.c4m") &
                        staticRead("configs/base_plugins.c4m") &
                        staticRead("configs/base_sinks.c4m") &
                        staticRead("configs/base_auths.c4m") &
                        staticRead("configs/base_chalk_templates.c4m") &
                        staticRead("configs/base_report_templates.c4m") &
                        staticRead("configs/base_outconf.c4m") &
                        staticRead("configs/base_sinkconfs.c4m") &
                        staticRead("configs/dockercmd.c4m") &
                        staticRead("configs/buildkitcmd.c4m")
  sbomConfig*         = staticRead(sbomConfName)
  sastConfig*         = staticRead(sastConfName)
  secretsConfig*      = staticRead(secretsConfName)
  ioConfig*           = staticRead(ioConfName)
  defaultConfig*      = staticRead(defCfgFname)
  attestConfig*       = staticRead(attestConfName)
  coConfig*           = staticRead(coConfName)
  commitID*           = staticExec("git log -n1 --pretty=format:%H")
  archStr*            = staticExec("uname -m")
  osStr*              = staticExec("uname -o")
  stdinIndicator*     = ":stdin:"
  # various time formats
  timesDateFormat*    = "yyyy-MM-dd"
  timesTimeFormat*    = "HH:mm:ss'.'fff"
  timesTzFormat*      = "zzz"
  timesIso8601Format* = timesDateFormat & "'T'" & timesTimeFormat & timesTzFormat
  objectStorePrefix*  = "@"

  allResourceTypes*   = { ResourceFile, ResourceImage, ResourceContainer, ResourcePid, ResourceCert }
  defResourceTypes*   = allResourceTypes - { ResourceCert }

  # Make sure that ARTIFACT_TYPE fields are consistently named
  artTypeElf*             = "ELF"
  artTypeZip*             = "ZIP"
  artTypeJAR*             = "JAR"
  artTypeWAR*             = "WAR"
  artTypeEAR*             = "EAR"
  artTypeDockerImage*     = "Docker Image"
  artTypeDockerContainer* = "Docker Container"
  artTypePyc*             = "Python Bytecode"
  artTypeMachO*           = "Mach-O executable"
  artX509Cert*            = "x509 Cert"

var
  hostInfo*               = ChalkDict()
  objectsData*            = ObjectsDict()
  failedKeys*             = ChalkDict()
  subscribedKeys*         = Table[string, bool]()
  systemErrors*           = seq[string](@[])
  selfChalk*              = ChalkObj(nil)
  selfId*                 = none(string)
  canSelfInject*          = true
  doingTestRun*           = false
  onlyCodecs*             = newSeq[Plugin]()
  passedHelpFlag*         = false
  installedPlugins*       = Table[string, Plugin]()
  externalActions*        = newSeq[seq[string]]()
  commandName*            = ""
  sshKeyscanExeLocation*  = ""
  dockerInvocation*:      DockerInvocation # ca be nil

template dumpExOnDebug*() =
  when not defined(release):
    let stack = getCurrentException().getStackTrace()
    if getChalkScope() != nil and attrGet[bool]("chalk_debug"):
      let
        msg = "" # "Handling exception (msg = " & getCurrentExceptionMsg() & ")\n"
        tb  = "Traceback (most recent call last)\n" & stack
        ii  = default(InstInfo)
        fmt = formatCompilerError(msg, nil, tb, ii)
      publish("debug", fmt)
    else:
      trace(stack)

proc getBaseCommandName*(): string =
  if '.' in commandName:
    result = commandName.split('.')[0]
  else:
    result = commandName
