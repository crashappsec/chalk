##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/re
import std/tables
import std/hashes
import std/sets
import std/sequtils
import ../config, ../plugin_api
import typetraits

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

proc scanFile(filePath: string, category: string, subcategory: string) =
  var strm = newFileStream(filePath, fmRead)
  if isNil(strm):
    return

  let splFile = splitFile(filePath)
  let rule_names = categories[category][subcategory]
  var applicable_rules: seq[string]
  # applicable rules are eithr rules that apply to all filetypes (FT_ANY)
  # or to the filetype matching the given extension
  for rule_name in categories[category][subcategory]:
    if contains(excludePthRules, filePath) and contains(excludePthRules[filePath], rule_name):
      continue

    # first check if the rule should always be added for this exact file path
    if contains(pthRules, filePath) and contains(pthRules[filePath], rule_name):
      applicable_rules.add(rule_name)
      continue

    # If we don't have a filepath based, match, go by file extension and check
    # if the extension should be getting excluded or not.

    # first check if the rule applies to all file types (FT_ANY). In this
    # case we may only have excluded filetypes, so make a pass for those,
    # otherwise add it
    if not contains(tsRules, rule_name):
      continue

    let tsRule = tsRules[rule_name]
    if contains(ftRules, FT_ANY) and contains(ftRules[FT_ANY], rule_name):

      # make a pass and check if we should exclude the rule
      var exclude = false
      if contains(ruleExcludeFiletypes, rule_name):
        for ft in ruleExcludeFiletypes[rule_name]:
          # if the filetype does not match the current extension proceed
          if ft != splFile.ext and ft != "":
              continue
          # if we have a matching extension and a rule for that extenion,
          # append the rule in the rule to be run
          if contains(excludeFtRules, ft) and contains(excludeFtRules[ft], rule_name):
              exclude = true
              break
      # add the rule only if its explicitly added and not excluded
      if not exclude:
        applicable_rules.add(rule_name)

      # done processing FT_ANY
      continue

    # if the rule does not apply to all filetypes, check the ones for which
    # it actually does apply.
    if contains(ruleFiletypes, rule_name):
      for ft in ruleFiletypes[rule_name]:
        # if the filetype does not match the current extension proceed
        if ft != splFile.ext and ft != "":
          continue

        # if we have a matching extension and a rule for that extenion,
        # append the rule in the rule to be run
        if contains(ftRules, ft) and contains(ftRules[ft], rule_name):
          applicable_rules.add(rule_name)
          break

  var line = ""
  var i = 0
  var abort = false
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
  strm.close()

proc getProcNames(): HashSet[string] =
  var names: seq[string]
  for kind, path in walkDir("/proc/"):
    for ch in path.splitPath().tail:
      try:
        if ch notin "0123456789":
          continue
        let p_path = path / "status"
        var data = p_path.readFile()
        for line in data.split("\n"):
          if "Name:" in line:
            var name = line.split("Name:")[1].strip()
            names.add(name)
      except:
         continue
  result = toHashSet(names)

# The current host based detection simply checks for the
# presence of configuration files, therefore we don't need
# to do more thatn check if the file paths exist. However we could
# expand with proper plugins per category looking for things like
# ps output etc in upcoming revisions
proc hostHasTechStack(scope: hostScope, proc_names: HashSet[string]): bool =
  # first check directories and filepaths, then processes
  let scopedDirs = scope.getDirectories()
  if scopedDirs.isSome():
    for path in scopedDirs.get():
      if dirExists(path):
        return true

  let filepaths = scope.getFilepaths()
  if filepaths.isSome():
    for path in filepaths.get():
      if fileExists(path):
        return true

  let names = scope.getProcessNames()
  if names.isSome():
    let rule_names = toHashSet(names.get())
    let intersection = proc_names * rule_names
    if len(intersection) > 0:
      return true

  return false

# FIXME check that we don't fall into infinite loops with a symlink here
proc scanDirectory(directory: string, category: string, subcategory: string) =
  if inFileScope[category][subcategory]:
    return
  for filePath in walkDir(directory):
    if inFileScope[category][subcategory]:
      break
    if filePath.kind == pcFile:
      scanFile(filePath.path, category, subcategory)
      continue
    if filePath.kind == pcDir:
      scanDirectory(filePath.path, category, subcategory)
      continue

proc getLanguages(directory: string, langs: var HashSet[string]) =
  for filePath in walkDir(directory):
    if filePath.kind == pcFile:
      let splFile = splitFile(filePath.path)
      if splFile.ext == "":
        continue
      if not contains(languages, splFile.ext):
        continue
      langs.incl(languages[splFile.ext])
      continue
    if filePath.kind == pcDir:
      getLanguages(filePath.path, langs)
      continue

proc detectLanguages(): HashSet[string] =
  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    return

  var langs: HashSet[string]
  for item in getContextDirectories():
    let fpath = expandFilename(item)
    if fpath.dirExists():
      getLanguages(fpath, langs)
    else:
      let (head, _) = splitPath(fPath)
      if head.dirExists():
          getLanguages(head, langs)
  return langs

proc detectTechCwd(): TableRef[string, seq[string]] =
  var final = newTable[string, seq[string]]()

  var hasResults = false
  for category, subcategories in categories:
    for subcategory, _ in subcategories:
      if (not (contains(inFileScope, category) and
          contains(inFileScope[category], subcategory))):
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
        if not (contains(inFileScope, category) and
          contains(inFileScope[category], subcategory)):
          continue
        if inFileScope[category][subcategory]:
          if contains(final, category):
            final[category].add(subcategory)
          else:
            final[category] = @[subcategory]
  return final

proc detectTechHostStatic(): TableRef[string, seq[string]] =
  var final_host = newTable[string, seq[string]]()
  for category, subcategories in categories:
    for subcategory, _ in subcategories:
      if (contains(inHostScope, category) and
          contains(inHostScope[category], subcategory) and
          inHostScope[category][subcategory]):
        if contains(final_host, category):
          final_host[category].add(subcategory)
        else:
          final_host[category] = @[subcategory]
  return final_host

proc techStackRuntime*(self: Plugin, objs: seq[ChalkObj]):
  ChalkDict {.cdecl.} =

  result = ChalkDict()
  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    trace("Skipping tech stack runtime detection plugin")
    return

  let procNames = getProcNames()

  for key, val in chalkConfig.techStackRules:
    if val.hostScope == nil:
      continue
    for category, subcategories in categories:
      for subcategory, _ in subcategories:
        if (contains(inHostScope, category) and
            contains(inHostScope[category], subcategory) and
            (not inHostScope[category][subcategory])):
          inHostScope[category][subcategory] = hostHasTechStack(val.hostScope, procNames)

  var final_host = newTable[string, seq[string]]()
  for category, subcategories in categories:
    for subcategory, _ in subcategories:
      if (contains(inHostScope, category) and
          contains(inHostScope[category], subcategory) and
          inHostScope[category][subcategory]):
        if contains(final_host, category):
            final_host[category].add(subcategory)
        else:
            final_host[category] = @[subcategory]
  if len(final_host) > 0:
    result["_INFERRED_TECH_STACKS_HOST"] = pack[TableRef[string, seq[string]]](final_host)

proc techStackArtifact*(self: Plugin, objs: ChalkObj):
  ChalkDict {.cdecl.} =

  result = ChalkDict()
  let canLoad = chalkConfig.getUseTechStackDetection()
  if not canLoad:
    trace("Skipping tech stack detection plugin for artifacts")
    return

  var final = detectTechCwd()
  var final_host = detectTechHostStatic()
  let langs = detectLanguages()
  if len(langs) > 0:
    if len(final) == 0:
      var final = newTable[string, seq[string]]()
    final["language"] = toSeq(langs)

  if len(final) > 0:
    result["_INFERRED_TECH_STACKS"]      = pack[TableRef[string, seq[string]]](final)
  if len(final_host) > 0:
    result["_INFERRED_TECH_STACKS_HOST"] = pack[TableRef[string, seq[string]]](final_host)

proc loadtechStackGeneric*() =
  for langName, val in chalkConfig.linguistLanguages:
    languages[val.getExtension()] = langName

  for key, val in chalkConfig.techStackRules:
    let category = val.getCategory()
    let subcategory = val.getSubcategory()

    if contains(categories, category):
      if contains(categories[category], subcategory):
        categories[category][subcategory].add(key)
      else:
        categories[category][subcategory] = @[key]
    else:
      categories[category] = newTable[string, seq[string]]()
      categories[category][subcategory] = @[key]

    if val.hostScope != nil:
      if not contains(inHostScope, category):
        inHostScope[category] = newTable[string, bool]()
        inHostScope[category][subcategory] = false
    else:
      if val.fileScope == nil:
        error("One of file_scope, host_scope must be defined for rule " & key & ". Skipping")
        continue
      if not contains(inFileScope, category):
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
          if contains(ftRules, ft):
            ftRules[ft].incl(key)
          else:
            ftRules[ft] = toHashSet([key])
      else:
        # we only have exclude rules therefore we match by default
        # XXX move to a template for looking things up and adding if
        # they don't exist
        if contains(ftRules, FT_ANY):
          ftRules[FT_ANY].incl(key)
        else:
          ftRules[FT_ANY] = toHashSet([key])
        let excludeFiletypes = val.fileScope.getExcludedFiletypes()
        if excludeFiletypes.isSome():
          let exclFtps = excludeFiletypes.get()
          ruleExcludeFiletypes[key] = exclFtps
          for ft in exclFtps:
            if contains(excludeFtRules, ft):
              excludeFtRules[ft].incl(key)
            else:
              excludeFtRules[ft] = toHashSet([key])

      # get paths and excluded paths that need to always be considered
      let filepaths = val.fileScope.getFilepaths()
      if filepaths.isSome():
        let fpaths = filepaths.get()
        for path in fpaths:
          if contains(pthRules, path):
            pthRules[path].incl(key)
          else:
            pthRules[path] = toHashSet([key])

      let excludeFilepaths = val.fileScope.getExcludedFilepaths()
      if excludeFilepaths.isSome():
        let excfpaths = excludeFilepaths.get()
        for path in excfpaths:
          if contains(excludePthRules, path):
            excludePthRules[path].incl(key)
          else:
            excludePthRules[path] = toHashSet([key])

  newPlugin("techStackGeneric",
            ctArtCallback  = ChalkTimeArtifactCb(techStackArtifact),
            rtHostCallback = RunTimeHostCb(techStackRuntime))
