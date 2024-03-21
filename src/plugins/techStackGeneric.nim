##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[hashes, re, sequtils, sets, strscans, tables]
import pkg/nimutils
import ".."/[config, plugin_api, util]

const FT_ANY = "*"
var
  languages            = newTable[string, string]()
  # rule identifiers by exact path
  pthRules             = newTable[string, HashSet[string]]()
  # rules to exclude by exact path
  excludePthRules      = newTable[string, HashSet[string]]()
  # rule identifiers by filetype
  ftRules              = newTable[string, HashSet[string]]()
  # rules to be excluded from given filetypes
  excludeFtRules       = newTable[string, HashSet[string]]()
  # tech stack rules by each identifier
  tsRules              = newTable[string, TechStackRule]()
  # regex by name
  regexes              = newTable[string, Regex]()
  # category: [subcategory: seq[regex_name]]
  categories           = newTable[string, TableRef[string, seq[string]]]()
  # category: [subcategory: bool]
  inFileScope          = newTable[string, TableRef[string, bool]]()
  # category: [subcategory: bool]
  inHostScope          = newTable[string, TableRef[string, bool]]()
  # limits for what portion from the start of the file a rule must read into
  headLimits           = newTable[string, int]()

  # key: rule, vals: filetypes for which this rules applies
  ruleFiletypes        = newTable[string, seq[string]]()
  # key: rule, vals: filetypes for which this rules does not applies
  ruleExcludeFiletypes = newTable[string, seq[string]]()

proc scanFileStream(strm: FileStream, filePath: string, category: string, subcategory: string) =
  let
    splFile    = splitFile(filePath)
    rule_names = categories[category][subcategory]
  var applicable_rules: seq[string]
  # applicable rules are eithr rules that apply to all filetypes (FT_ANY)
  # or to the filetype matching the given extension
  for rule_name in categories[category][subcategory]:
    if filePath in excludePthRules and rule_name in excludePthRules[filePath]:
      continue

    # first check if the rule should always be added for this exact file path
    if filePath in pthRules and rule_name in pthRules[filePath]:
      applicable_rules.add(rule_name)
      continue

    # If we don't have a filepath based, match, go by file extension and check
    # if the extension should be getting excluded or not.

    # first check if the rule applies to all file types (FT_ANY). In this
    # case we may only have excluded filetypes, so make a pass for those,
    # otherwise add it
    if rule_name notin tsRules:
      continue

    let tsRule = tsRules[rule_name]
    if FT_ANY in ftRules and rule_name in ftRules[FT_ANY]:

      # make a pass and check if we should exclude the rule
      var exclude = false
      if rule_name in ruleExcludeFiletypes:
        for ft in ruleExcludeFiletypes[rule_name]:
          # if the filetype does not match the current extension proceed
          if ft != splFile.ext and ft != "":
              continue
          # if we have a matching extension and a rule for that extenion,
          # append the rule in the rule to be run
          if ft in excludeFtRules and rule_name in excludeFtRules[ft]:
              exclude = true
              break
      # add the rule only if its explicitly added and not excluded
      if not exclude:
        applicable_rules.add(rule_name)

      # done processing FT_ANY
      continue

    # if the rule does not apply to all filetypes, check the ones for which
    # it actually does apply.
    if rule_name in ruleFiletypes:
      for ft in ruleFiletypes[rule_name]:
        # if the filetype does not match the current extension proceed
        if ft != splFile.ext and ft != "":
          continue

        # if we have a matching extension and a rule for that extenion,
        # append the rule in the rule to be run
        if ft in ftRules and rule_name in ftRules[ft]:
          applicable_rules.add(rule_name)
          break

  var
    line  = ""
    i     = 0
    abort = false
  while strm.readLine(line):
    i += 1
    if inFileScope[category][subcategory] or abort:
      break

    for rule_name in applicable_rules:
      if i >= headLimits[rule_name]:
        abort = true
        break

      if find(line, regexes[rule_name]) != -1:
        inFileScope[category][subcategory] = true
        break

proc scanFile(filePath: string, category: string, subcategory: string) =
  withFileStream(filePath, mode = fmRead, strict = true):
    if stream == nil:
      return
    scanFileStream(stream, filePath, category, subcategory)

proc getProcNames(): HashSet[string] =
  ## Returns every Name value in files at `/proc/[0-9]+/status`.
  ## This is the filename of each executable, truncated to 15 characters.
  result = initHashSet[string]()
  for kind, path in walkDir("/proc/"):
    if kind == pcDir and path.lastPathPart().allIt(it in {'0'..'9'}):
      let data = tryToLoadFile(path / "status")
      for line in data.splitLines():
        let (isMatch, name) = line.scanTuple("Name:$s$+")
        if isMatch:
          result.incl(name)
          break

# The current host based detection simply checks for the
# presence of configuration files, therefore we don't need
# to do more thatn check if the file paths exist. However we could
# expand with proper plugins per category looking for things like
# ps output etc in upcoming revisions
proc hostHasTechStack(scope: hostScope, proc_names: HashSet[string]): bool =
  # first check directories and filepaths, then processes
  let scopedDirs = scope.getDirectories()
  var fExists = false
  var dExists = false

  if scopedDirs.isSome():
    for path in scopedDirs.get():
      if dirExists(path):
        dExists = true
        break

  let filepaths = scope.getFilepaths()
  if filepaths.isSome():
    for path in filepaths.get():
      if fileExists(path):
        fExists = true
        break

  let names = scope.getProcessNames()
  if names.isSome():
    let
      rule_names   = toHashSet(names.get())
      intersection = proc_names * rule_names
    if len(intersection) > 0:
      if scope.getStrict():
        return fExists or dExists
      return true

  return false

# FIXME check that we don't fall into infinite loops with a symlink here
proc scanDirectory(directory: string, category: string, subcategory: string) =
  if inFileScope[category][subcategory]:
    return
  for kind, path in walkDir(directory):
    if inFileScope[category][subcategory]:
      break
    if kind == pcFile:
      scanFile(path, category, subcategory)
    elif kind == pcDir:
      scanDirectory(path, category, subcategory)

proc getLanguages(directory: string, langs: var HashSet[string]) =
  for kind, path in walkDir(directory):
    if kind == pcFile:
      let ext = path.splitFile().ext
      if ext != "" and ext in languages:
        langs.incl(languages[ext])
    elif kind == pcDir:
      getLanguages(path, langs)

proc detectLanguages(): HashSet[string] =
  result = initHashSet[string]()

  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    return result

  for item in getContextDirectories():
    let fpath = expandFilename(item)
    if fpath.dirExists():
      getLanguages(fpath, result)
    else:
      let (head, _) = splitPath(fPath)
      if head.dirExists():
          getLanguages(head, result)

proc detectTechCwd(): TableRef[string, seq[string]] =
  result = newTable[string, seq[string]]()
  var hasResults = false
  for category, subcategories in categories:
    for subcategory, _ in subcategories:
      if not (category in inFileScope and subcategory in inFileScope[category]):
        continue
      # re-initialize to false again
      # XXX check the diff between load time and invocation state
      # does this need to be re-set upon every invocation here?
      inFileScope[category][subcategory] = false
      for item in getContextDirectories():
        if inFileScope[category][subcategory]:
          break
        let fpath = expandFilename(item)
        if fpath.dirExists():
          scanDirectory(fpath, category, subcategory)
        else:
          let (head, _) = splitPath(fPath)
          if head.dirExists():
            scanDirectory(head, category, subcategory)
      if inFileScope[category][subcategory]:
        hasResults = true

  if hasResults:
    for category, subcategories in categories:
      for subcategory, _ in subcategories:
        if not (category in inFileScope and subcategory in inFileScope[category]):
          continue
        if inFileScope[category][subcategory]:
          result.mgetOrPut(category, @[]).add(subcategory)

proc loadState() =
  once:
    for langName, val in chalkConfig.linguistLanguages:
      languages[val.getExtension()] = langName

    for key, val in chalkConfig.techStackRules:
      let
        category    = val.getCategory()
        subcategory = val.getSubcategory()

      categories.
        mgetOrPut(category, newTable[string, seq[string]]()).
        mgetOrPut(subcategory, @[]).
        add(key)

      if val.hostScope != nil:
        if category notin inHostScope:
          inHostScope[category] = newTable[string, bool]()
          inHostScope[category][subcategory] = false
      else:
        if val.fileScope == nil:
          error("One of file_scope, host_scope must be defined for rule " & key & ". Skipping")
          continue
        if category notin inFileScope:
          inFileScope[category] = newTable[string, bool]()
        inFileScope[category][subcategory] = false

        tsRules[key] = val
        regexes[key] = re(val.fileScope.getRegex())
        headLimits[key] = val.fileScope.getHead()
        let filetypes = val.fileScope.getFiletypes()
        if filetypes.isSome():
          let ftypes = filetypes.get()
          ruleFiletypes[key] = ftypes
          for ft in ftypes:
            ftRules.mgetOrPut(ft, initHashSet[string]()).incl(key)
        else:
          # we only have exclude rules therefore we match by default
          # XXX move to a template for looking things up and adding if
          # they don't exist
          ftRules.mgetOrPut(FT_ANY, initHashSet[string]()).incl(key)
          let excludeFiletypes = val.fileScope.getExcludedFiletypes()
          if excludeFiletypes.isSome():
            let exclFtps = excludeFiletypes.get()
            ruleExcludeFiletypes[key] = exclFtps
            for ft in exclFtps:
              excludeFtRules.mgetOrPut(ft, initHashSet[string]()).incl(key)

        # get paths and excluded paths that need to always be considered
        let filepaths = val.fileScope.getFilepaths()
        if filepaths.isSome():
          let fpaths = filepaths.get()
          for path in fpaths:
            pthRules.mgetOrPut(path, initHashSet[string]()).incl(key)

        let excludeFilepaths = val.fileScope.getExcludedFilepaths()
        if excludeFilepaths.isSome():
          let excfpaths = excludeFilepaths.get()
          for path in excfpaths:
            excludePthRules.mgetOrPut(path, initHashSet[string]()).incl(key)

proc techStackRuntime*(self: Plugin, objs: seq[ChalkObj]): ChalkDict {.cdecl.} =
  result = ChalkDict()
  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    trace("Skipping tech stack runtime detection plugin")
    return result

  loadState()
  let procNames = getProcNames()
  var finalHost = newTable[string, seq[string]]()

  for key, val in chalkConfig.techStackRules:
    if val.hostScope == nil:
      continue
    let
      category    = val.getCategory()
      subcategory = val.getSubcategory()
    if (category in inHostScope and
        subcategory in inHostScope[category] and
        not inHostScope[category][subcategory]):
      let isTechStack = hostHasTechStack(val.hostScope, procNames)
      inHostScope[category][subcategory] = isTechStack
      if isTechStack:
        finalHost.mgetOrPut(category, @[]).add(subcategory)

  if len(finalHost) > 0:
    result["_INFERRED_TECH_STACKS_HOST"] = pack[TableRef[string, seq[string]]](finalHost)

proc techStackArtifact*(self: Plugin, objs: ChalkObj): ChalkDict {.cdecl.} =
  result = ChalkDict()
  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    trace("Skipping tech stack detection plugin for artifacts")
    return result

  loadState()
  let
    final      = detectTechCwd()
    langs      = detectLanguages()
  if len(langs) > 0:
    final["language"] = toSeq(langs)

  if len(final) > 0:
    result["INFERRED_TECH_STACKS"]      = pack[TableRef[string, seq[string]]](final)

proc loadtechStackGeneric*() =
  newPlugin("tech_stack_generic",
            ctArtCallback  = ChalkTimeArtifactCb(techStackArtifact),
            rtHostCallback = RunTimeHostCb(techStackRuntime))
