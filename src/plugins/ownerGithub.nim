## Looks for and parses github CODEOWNERS files.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, streams, os, ../config, ../plugins


const
  fNameGHCO = "CODEOWNERS"
  dirGH     = ".github"
  gitRoot   = ".git"
  dirDoc    = "docs"

proc findCOFile(fullpath: string): string =
  let (head, tail) = splitPath(fullpath)
  if tail == "": return ""

  if fullpath.dirExists():
    # if we are in a directory, we only care about the root of the repo
    let gitDir = fullpath.joinPath(gitRoot)
    if not gitDir.dirExists(): return head.findCOFile()
  else:
    # otherwise either we are examining a CODEOWNERS file or traverse up
    if tail == fNameGHCO: return fullpath
    return head.findCOFile()

  let cofname = fullpath.joinPath(fNameGHCO)
  if cofname.fileExists(): return cofname

  let ghdir = fullpath.joinPath(dirGH)

  if ghdir.dirExists():
    let cogh = ghdir.joinPath(fNameGHCO)
    if cogh.fileExists():  return cogh
    else: return "" # Stop here.

  let docdir = fullpath.joinPath(dirDoc)

  if docdir.dirExists():
    let codoc = docdir.joinPath(fNameGHCO)
    if codoc.fileExists(): return codoc

  return "" # nothing here


type GithubCodeOwner = ref object of Plugin

method getChalkInfo*(self: GithubCodeOwner, obj: ChalkObj): ChalkDict =
  # CODEOWNERS can live in the root of a repo, the docs subdir, or
  # the .github directory of a repository.  The challenge is that we
  # don't actually know where the root directory is, relative to the
  # command line arguments passed.
  #
  # The algorithm we use then is to start at our file, look for one
  # of the three options in that dir, and keep backing up until we
  # see a CODEOWNERS file or a .github dir (we don't stop at docs in
  # case we're in some subdirectory below the root that also has a
  # docs dire in it.
  #
  # We let this go all the way up to the root of the fs \_("/)_/
  result = ChalkDict()

  var fname = obj.fullPath.findCOFile()
  if fname == "": return
  var ctx: FileStream

  try:
    ctx = newFileStream(fname, fmRead)
    if ctx == nil: error(fname & ": Could not open file.")
    else:
      let m = ctx.readAll()

      if m != "": result["CODE_OWNERS"] = pack(m)
  except:
    error(fname & ": File found, but could not be read: " &
                                           getCurrentExceptionMsg())
    dumpExOnDebug()
  finally:
    if ctx != nil: ctx.close()

registerPlugin("github_codeowners", GithubCodeOwner())
