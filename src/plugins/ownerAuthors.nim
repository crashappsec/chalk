##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Plugin that looks for an old school AUTHOR/AUTHORS file.

import ".."/[config, plugin_api]

const
  fNameAuthor  = "AUTHOR"
  fNameAuthors = "AUTHORS"
  dirDoc       = "docs"
  gitRoot      = ".git"

proc findAuthorsFile(fullpath: string): string =
  let (head, tail) = splitPath(fullpath)
  if tail == "": return ""

  if fullpath.dirExists():
    # if we are in a directory, we only care about the root of the repo
    let gitDir = fullpath.joinPath(gitRoot)
    if not gitDir.dirExists(): return head.findAuthorsFile()
  else:
    # otherwise either we are examining an AUTHOR(s) file or traverse up
    if tail == fNameAuthor or tail == fNameAuthors: return fullpath
    return head.findAuthorsFile()

  let
    authfname  = fullpath.joinPath(fNameAuthor)
    authsfname = fullpath.joinPath(fNameAuthors)
    docdir     = fullpath.joinPath(dirDoc)

  if authfname.fileExists():  return authfname
  if authsfname.fileExists(): return authsfname

  if docdir.dirExists():
    let
      authdoc  = docdir.joinPath(fNameAuthor)
      authsdoc = docdir.joinPath(fNameAuthors)

    if authdoc.fileExists():  return authdoc
    if authsdoc.fileExists(): return authsdoc

  return ""

proc authorsGetChalkTimeArtifactInfo*(self: Plugin, ignore: ChalkObj): ChalkDict {.cdecl.} =
  result = ChalkDict()

  var fname: string

  for item in getContextDirectories():
    fname = item.findAuthorsFile()
    if fname != "": break

  if fname == "": return

  try:
    let s = tryToLoadFile(fname)
    if s != "":
      result["CODE_OWNERS"] = pack(s)
  except:
    error(fname & ": File found, but could not be read due to: " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc loadOwnerAuthors*() =
  newPlugin("authors",
          ctArtCallback = ChalkTimeArtifactCb(authorsGetChalkTimeArtifactInfo))
