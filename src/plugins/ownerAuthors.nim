## Plugin that looks for an old school AUTHOR/AUTHORS file.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, os, streams, ../config, ../plugins

const
  fNameAuthor  = "AUTHOR"
  fNameAuthors = "AUTHORS"
  dirDoc       = "docs"
  gitRoot      = ".git"

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

proc findAuthorsFile(fullpath: string): string =
  let (head, tail) = splitPath(fullpath)
  if tail == "": return ""

  if fullpath.dirExists():
    # if we are in a directory, we only care about the root of the repo
    let gitDir = fullpath.joinPath(gitRoot)
    if not gitDir.dirExists(): return head.findAuthorsFile()
  else:
    # otherwise either we are examining an AUTHOR(s) file or traverse up
    if tail == fNameAuthor or tail == fnameAuthors: return fullpath
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

type AuthorsFileCodeOwner* = ref object of Plugin


method getHostInfo*(self: AuthorsFileCodeOwner,
                    path: seq[string],
                    ins:  bool): ChalkDict =
  result = ChalkDict()

  var fname: string

  for item in path:
    fname = item.findAuthorsFile()
    if fname != "": break

  if fname == "": return

  var ctx: FileStream

  try:
    ctx = newFileStream(fname, fmRead)
    if ctx == nil: error(fname & ": Could not open file")
    else:
      let s = ctx.readAll()
      if s != "": result["CODE_OWNERS"] = pack(s)
  except:
    error(fname & ": File found, but could not be read")
    dumpExOnDebug()
  finally:
    if ctx != nil: ctx.close()

registerPlugin("authors", AuthorsFileCodeOwner())
