# We centralize all our resources (mostly strings) into this file.
# The main purpose is to facilitate localization.  All of these values
# are exported since none of them are used in this module directly.

import terminal
import os

const
  # This first section constitutes items that are part of the
  # spec and should never be changed, unless the spec changes.
  firstSpecVersion* = "1.0.0"
  specVersion* = "1.0.0"
  magicUTF8* = "dadfedabbadabbed"
  magicBin* = "\xda\xdf\xed\xab\xba\xda\xbb\xed"
  magicSwapped* = "\xed\xbb\xda\xba\xab\xed\xdf\xda"
  elfMagic* = 0x7f454c46'u32
  elfSwapped* = 0x464c457f'u32
  prefixExt* = "X-"

  # Errors used in config code.
  eConflictFmt* = "Conflicting flags provided: {l1} ({s1}) and {l2} ({s2})"
  eBadBoolEnv* = "Boolean envvar {envVar} ignored (invalid value: {contents}"
  eBadLogLevel* = "{envVar} isn't a valid log level: {contents}"
  eBadSection* = "{fullname}: Invalid section name: {e.section} (Ignored)"
  eBadCfgKey* = "{fullname}: Invalid configuration key: {key}"
  eNotBoolCf* = "{fullname}: Invalid boolean value for key {key}"
  eNotLLCf* = "{fullname}: Invalid log level for key {key}"
  eCfgOpen* = "{fullname}: Could not open configuration file."
  eFileOpen* = "{filename}: Could not open file." # also used in contexts.nim
  eBadCfgFile* = "{fullname}: Configuration file cannot be read."
  eDupeCfg* = "{fullname}: Duplicate key {k} in config file ignored"
  eBadUInsert* = "{fullname}: Config file has a invalid user insertion: {key}"

  # sami.nim -- the main module, which does mainly command line
  # parsing, then dispatches.
  fColorShort* = "-a"
  fColorLong* = "--color"
  fNoColorShort* = "-A"
  fNoColorLong* = "--no-color"
  fDryRunShort* = "-d"
  fDryRunLong* = "--dry-run"
  fNoDryRunShort* = "-D"
  fNoDryRunLong* = "--no-dry-run"
  fSilentShort* = "-z"
  fSilentLong* = "--silent"
  fQuietShort* = "-q"
  fQuietLong* = "--quiet"
  fNormalShort* = "-n"
  fNormalLong* = "--normal-output"
  fVerboseShort* = "-v"
  fVerboseLong* = "--verbose"
  fTraceShort* = "-t"
  fTraceLong* = "--trace"
  fCfgFileNameShort* = "-c"
  fCfgFileNameLong* = "--config-file-name"
  fCfgSearchPathShort* = "-p"
  fCfgSearchPathLong* = "--config-search-path"
  fOverwriteShort* = "-w"
  fOverwriteLong* = "--overwrite"
  fNoOverwriteShort* = "-W"
  fNoOverwriteLong* = "--no-overwrite"
  fRecursiveShort* = "-r"
  fRecursiveLong* = "--recursive"
  fNoRecursiveShort* = "-R"
  fNoRecursiveLong* = "--no-recursive"
  fOutputFileShort* = "-o"
  fOutputFileLong* = "--output-file"
  fOutputDirShort* = "-d"
  fOutputDirLong* = "--output-dir"

  # TODO: stick these in arrays and use macros to generate code.
  cmdNameInject1* = "inject"
  cmdNameInject2* = "insert"
  cmdNameInject3* = "ins"
  cmdNameInject4* = "in"
  cmdNameInject5* = "i"


  cmdNameExtract1* = "extract"
  cmdNameExtract2* = "ex"
  cmdNameExtract3* = "x"

  cmdNameEnv1* = "environment"
  cmdNameEnv2* = "environ"
  cmdNameEnv3* = "env"
  cmdNameEnv4* = "e"

  cmdNameDefaults1* = "defaults"
  cmdNameDefaults2* = "def"
  cmdNameDefaults3* = "d"

  flagFmt* = "$# ($#)"

  # help strings for the command line.
  insertHelp* = "Insert SAMIs into artifacts"
  extractHelp* = "Extract SAMIs from artifacts"
  envHelp* = """Show info about SAMI environment variables

SAMI defines the following environment variables that are checked before 
looking for configuration files:

  {envCfgPath:17} The search path for configuration files. 
                        Default: {defaultCfgPath}
                        Override with: --config-search-path (-p)
  {envCfgFname:17} The file name to use for the configuration file.
                        Default: {defaultCfgFile}
                        Override with: --config-file-name (-c)

The remainder of the environment variables get applied AFTER reading the
configuration file, (if any). 

The following env variables apply to both 'insert' and 'extract' commands:
  {envLogLevel:17} Set the log level to:
                        'silent', 'quiet', 'normal', 'verbose' or 'trace'. 
                      Note that 'quiet' suppresses warnings, but not errors.
                        Default: normal
                        Override with: --quiet (-q)
                                       --normal-output (-n) 
                                       --verbose (-v)
                                       --silent (-z)
                                       --trace (-t)
  {envNoRecurse:17} When defined, the search for artifacts will not recurse into
                      subdirectories.
                        Override with: --recursive (-r)
  {envDryRun:17} When defined, no files will be written.
                        Override with: --no-dry-run (-D)
  {envNoColor:17} When defined, supress color in error messages.
                        Override with: --color (-A)
  {envArtifactPath:17} When defined, specify the search path for finding artifacts.
                        Default: . (current working directory)
                        Override with: command line arguments

The following environment variables only apply to SAMI insertion:
  {envOverWrite:17} When defined, artifacts that already have SAMI objects
                      will have those artifacts replaced, instead of 
                      incorporating them.
                        Override with: --no-overwrite (-W)

The following environment variables only apply to SAMI extraction:
  {envExtractFile:17} Specifies the output file name for extracted SAMI objects
                        Default: {defaultCfgOutFile}
                        Override with: --output-file (-o)
  {envExtractDir:17} Specifies the directory for the output file
                        Default: {defaultCfgOutDir}
                        Override with: --output-dir (-d)
"""

  generalHelp* = """{prog}: insert or extract software artifact metadata.
Default options shown can be overridden by config file or environment 
variables, where provided. Use --show-defaults to see what values would
be used, given the impact of config files / environment variables.
"""

  colorHelp* = "Turn on color in error messages"
  noColorHelp* = "Turn OFF color in error messages"
  dryRunHelp* = "Do not write files; output to terminal what would have\n" &
              "\t\t\t     been done. Shows which files would have metadata\n" &
              "\t\t\t     inserted / extracted, and what metadata is present"
  noDryRunHelp* = "Turn off dry run (if defined via env variable or conf file"
  silentHelp* = "Doesn't output any messages (except with --dry-run)"
  quietHelp* = "Only outputs if there's an error (or --dry-run output)"
  normalHelp* = "Output at normal logging level (warnings, but not too chatty)"
  verboseHelp* = "Output basic information during run"
  traceHelp* = "Output detailed tracing information"
  showDefHelp* = "Show what options will be selected, and why. Considers\n" &
              "\t\t\t     the impact of any config file, environment \n" &
              "\t\t\t     variables and options passed before this flag appears"
  cfgFileHelp* = "Specify the config file name to search for (NOT the path)"
  cfgSearchHelp* = "The search path for looking for configuration files"
  inFilesHelp* = "Specify which files or directories to target for insertion."
  overWriteHelp* = "Replace existing SAMI metadata found in an artifact"
  noOverWriteHelp* = "Keep existing SAMI metadata found in an artifact by\n" &
                   "\t\t\t     embedding it in the OLD_SAMI field"
  recursiveHelp* = "Recurse any directories when looking for artifacts"
  noRecursiveHelp* = "Do NOT recurse into dirs when looking for artifacts." &
          "\t\t\t     If dirs are listed in arguments, the top-level files " &
          "\t\t\t     will be checked, but no deeper."
  outFilesHelp* = "Specify files/directories from which to extract SAMIs from"
  outFileHelp* = "Specify filename for extracted SAMIs. They are written in JSON, " &
               "\t\t\t     with binary objects converted to ASCII hex"
  outDirHelp* = "Specify directory into which to place extracted SAMI JSON, if not cwd"

  # The below is mainly consumed by config.nim, though the first bits are
  # confifuration defaults, which are printed out by the main module.
  defaultCfgColor* = true
  defaultCfgDryRun* = false
  defaultCfgPath* = @["~/.config", "/etc/xdg/", "/etc:."]
  defaultCfgFile* = "sami.cfg"
  defaultCfgOverwrite* = false
  defaultCfgRecursive* = true
  defaultCfgOutDir* = "."
  defaultCfgOutFile* = "sami-extractions.json"
  defaultCfgArtifactPath* = @["."]

  # config.nim

  # String constants for the config file, including config key names,
  # and section names.  These are all lower-case, whereas we
  # upper-case env vars.  But we do treat them as case-insensitive.

  sectionCfg* = "config"
  sectionDefaults* = "defaults"
  sectionForce* = "force"

  txtSilent* = "SILENT"
  txtQuiet* = "QUIET"
  txtNormal* = "NORMAL"
  txtVerbose* = "VERBOSE"
  txtTrace* = "TRACE"

  # cmds/extract.nim
  fmtFullPath* = "$#" & DirSep & "$#"
  fmtEmbedList* = "{embededJson}{sep}{embj}"
  # This is the logging template for JSON output.
  logTemplate* = """{ 
  "ARTIFACT_PATH" : "$#", 
  "ARTIFACT_HOST" : "$#",
  "SAMI" : $#,
  "EMBEDDED_SAMIS" : $#
}"""
  fmtInfoNoExtract* = "{sami.fullpath}: No SAMI found for extraction"
  fmtInfoYesExtract* = "{sami.fullpath}: SAMI extracted"
  fmtInfoNoPrimary* = "{sami.fullpath}: couldn't find a primary SAMI insertion"

  # codec/base.nim
  fmtTraceExEnter* = "[{codec}] Codec beginning extractions"
  fmtTraceExExit* = "[{codec}] Codec done with all extractions"
  fmtInfoExPrimary* = "{fname}: Extracted a SAMI"
  fmtInfoExEmbeds* = "{fname}: Extracted {sami.embeds.len()} embedded SAMI(s)"
  fmtTraceLoadArg* = "{path}: current command line argument"
  fmtTraceScanFile* = "{item}: scanning file"  
  fmtTraceScanFileP* = "{path}: scanning file"
  fmtTraceFIP* = "{sami.fullpath}: Found @{$pt.startOffset}"
  fmtTraceNIP* = "{sami.fullpath}: No SAMI; insert @{$pt.startOffset}"
  infWouldWrite* = "{item.fullPath}: Write SAMI (not performed; dry run)"
  infNewSami* = "{item.fullpath}: new artifact metadata added."
  infReplacedSami* = "{item.fullpath}: artifact metadata replaced."
  eCantInsert* = "{item.fullpath}: insertion failed!"
  eCantWrite* = "{sami.fullpath}: couldn't write out SAMI"
  eDidWrite* = "{sami.fullpath}: wrote SAMI successfully"
  eBadBin* = "{sami.fullpath}: Found binary SAMI magic, but SAMI didn't parse"
  ePathNotFound* = "{path}: No such file or directory"

  # codec/codecShebang
  sShebang* = "#!"

  # core/abstract.nim
  eRequiredKey* = "{fname}: SAMI missing required key, '{key}'"
  eInvalidType* = "{fname}: SAMI key '{key}' has a type that does not match " &
                 "any valid type known for this key."
  eDupeKey* = "{fname}: Duplicate entry for SAMI key '{key}'"
  # The below are currently all commented out until we add back in validation
  eOldCmd* = "{fname}: SAMI version is newer than parser version"
  eTooOldCmd* = "{fname}: MINIMUM SAMI output version is newer than parser"
  eBadVersion* = "{fname}: contents of {key} is not a valid version string"
  eBadTime* = "{fname}: {key} time > the current time on this system"
  eNestedMagic* = "{fname}: nested MAGIC value is invalid"

  # core/frombinary.nim
  eUnkObjT* = "(unknown object type)"
  eBoolParse* = "(when parsing bool)"
  eBinParse* = "(when parsing binary)"
  eStrParse* = "(when parsing string)"
  eBadJson* = "{sami.fullpath}: Invalid input JSON in file"

  # core/fromjson.nim
  eNoObj* = "{sami.fullpath}: provided JSON is not a JSON object" #
  eNoFloat* = "{fname}: JSon type for {key} is `float`, which is NOT " &
                    "a valid SAMI type"
  rawMagicKey* = "\"_MAGIC"

  # core/tobinary.nim
  kvPairBinFmt* = "{result}{binEncodeStr(outputkey)}{binEncodeItem(val)}"
  binStrItemFmt* = "\x01{u32ToStr(uint32(len(s)))}{s}"
  binIntItemFmt* = "\x02{u64ToStr(uint64(i))}"
  binTrue* = "\x03\x01"
  binFalse* = "\x03\x00"
  binArrStartFmt* = "\x05{u32ToStr(uint32(len(arr)))}"
  binNullType* = "\x00"
  binObjHdr* = "\x06{u32ToStr(uint32(len(self)))}"

  # core/tojson.nim
  jHexIndicator* = "x"
  jSonNeedsEscape* = ['x', 'X', '\'']
  samiJsonEscapeSequence* = "\'"
  comfyItemSep* = ", " # also used in extract.nim
  kvPairJFmt* = "{comma}{keyJson} : {valJson}" # also extract.nim
  jSonObjFmt* = "{ $# }"
  jsonArrFmt* = "[ $# ]"
  magicFmt* = "{{ {strKeyToJson(kMagic)} : \"{magicUTF8}\""

  # core/types.nim
  ePureVirtual* = "Method is not defined; it must be overridden"

  # plugins/plugbase.nim
  kOwner* = "owner"
  kVCtl* = "vctl"

  # plugins/ownerGithub.nim
  piNameGitHubCO* = "githubCO"
  fNameGHCO* = "CODEOWNERS"
  dirGH* = ".github"
  dirDoc* = "docs" # also used in ownerAuthors.nim
  eCantOpen* = "{fname}: File found, but could not be read"

  # plugins/ownerAuthors.nim
  piNameAuthorsCO* = "authorsCO"
  fNameAuthor* = "AUTHOR"
  fNameAuthors* = "AUTHORS"

  # plugins/vctlGit.nim
  piNameGit* = "gitVCtl"
  dirGit* = ".git"
  fNameHead* = "HEAD"
  fNameConfig* = "config"
  trVcsDir* = "version control dir: {self.vcsDir}"
  trBranch* = "branch: {self.branchName}"
  trCommit* = "commit ID: {self.commitID}"
  trOrigin* = "origin: {url}"
  wNotParsed* = "{confFileName}: Github configuration file not parsed."
  ghRef* = "ref:"
  ghBranch* = "branch"
  ghRemote* = "remote"
  ghUrl* = "url"
  ghOrigin* = "origin"
  ghLocal* = "local"

  # util/contexts.nim
  tmpFilePrefix* = "sami"
  tmpFileSuffix* = "-extract.json"

  # util/errors.nim
  fmtErrPrefix* = "{exename}: error: "
  errColor* = fgRed
  warnColor* = fgYellow
  infoColor* = fgGreen
  traceColor* = fgCyan
  debugColor* = fgMagenta
  fmtWarnPrefix* = "{exename}: warning: "
  fmtTracePrefix* = "{exename}: trace: "
  fmtInfoPrefix* = "{exename}: info: "
  nestedPrefix* = " (in nested SAMI) "
  fmtDebug* = "$1:$2: $3"
  errSep* = " "

  # parsers/gitConfig.nim
  eBadGitConf* = "Github configuration file is invalid"

  # parsers/json
  fmtReadTrace* = "read: {$c}; position now: {$s.getPosition()}"
  jNullStr* = "null" # also used in tojson.nim, ...
  jTrueStr* = "true"
  jFalseStr* = "false"
  eBadLiteral* = "Invalid JSON literal. Expected: "
  eDoubleNeg* = "Double negative in JSON not allowed"
  eWTF* = "Programming mistake, shouldn't happen"
  eNoExponent* = "Exponent expected"
  eBadUniEscape* = "Invalid \\u escape in JSON"
  eBadEscape* = "Invalid JSON escape command after '\\'"
  eEOFInStr* = "End of file in string"
  eBadUTF8* = "Invalid UTF-8 in JSON string literal"
  eBadArrayItem* = "Expected comma or end of array"
  eNoColon* = "Colon expected"
  eBadObjMember* = "Invalid JSON obj, expected , or }}, got: '{$c}'"
  eBadObject* = "Bad object, expected either } or a string key"
  eBadElementStart* = "Bad JSon at position: {s.getPosition()}"

when not defined(release):
  const fmtDebugPrefix* = "{exename}: DEBUG: "
