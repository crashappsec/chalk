## Plugin that looks for an old school AUTHOR/AUTHORS file.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, os, streams, strformat, nimutils, ../types, ../config, ../plugins

const
  fNameAuthor  = "AUTHOR"
  fNameAuthors = "AUTHORS"
  dirDoc       = "docs"
  eCantOpen    = "{fname}: File found, but could not be read"
  eFileOpen    = "{filename}: Could not open file."


when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

proc findAuthorsFile(fullpath: string): string =
  let (head, tail) = splitPath(fullpath)

  if tail == "": return ""

  let
    authfname  = head.joinPath(fNameAuthor)
    authsfname = head.joinPath(fNameAuthors)
    docdir     = head.joinPath(dirDoc)

  if authfname.fileExists():  return authfname
  if authsfname.fileExists(): return authsfname

  if docdir.dirExists():
    let
      authdoc  = docdir.joinPath(fNameAuthor)
      authsdoc = docdir.joinPath(fNameAuthors)

    if authdoc.fileExists():  return authdoc
    if authsdoc.fileExists(): return authsdoc

  return head.findAuthorsFile()

type AuthorsFileCodeOwner* = ref object of Plugin


method getArtifactInfo*(self: AuthorsFileCodeOwner, obj: ChalkObj): ChalkDict =
  result = newTable[string, Box]()

  let fname = obj.fullpath.findAuthorsFile()

  if fname == "":
    return

  var ctx: FileStream

  try:
    ctx = newFileStream(fname, fmRead)
    if ctx == nil:
      error(eFileOpen)
    else:
      let s = ctx.readAll()
      if s != "":
        result["CODE_OWNERS"] = pack(s)
  except:
    error(eCantOpen.fmt())
  finally:
    if ctx != nil:
      ctx.close()

registerPlugin("authors", AuthorsFileCodeOwner())
