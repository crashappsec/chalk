import ../config
import ../types
import ../plugins
import ../resources
import nimutils/box

import os
import streams
import tables
import strformat

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

proc findCOFile(fullpath: string): string =
  let (head, tail) = splitPath(fullpath)

  if tail == "": return ""

  let cofname = head.joinPath(fNameGHCO)

  if cofname.fileExists():
    return cofname

  let ghdir = head.joinPath(dirGH)

  if ghdir.dirExists():
    let cogh = ghdir.joinPath(fNameGHCO)
    if cogh.fileExists():
      return cogh
    else:
      return "" # Stop here.

  let docdir = head.joinPath(dirDoc)

  if docdir.dirExists():
    let codoc = docdir.joinPath(fNameGHCO)
    if codoc.fileExists():
      return codoc

  return head.findCOFile()

type GithubCodeOwner = ref object of Plugin

method getArtifactInfo*(self: GithubCodeOwner,
                        sami: SamiObj): KeyInfo =
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
  result = newTable[string, Box]()

  let fname = sami.fullpath.findCOFile()

  if fname == "":
    return

  var ctx: FileStream

  try:
    ctx = newFileStream(fname, fmRead)
    if ctx == nil:
      warn(eFileOpen)
    else:
      let s = ctx.readAll()
      # TODO-- match from the file instead of dumping the whole thing.
      if s != "":
        result["CODE_OWNERS"] = pack(s)
  except:
    warn(eCantOpen.fmt())
  finally:
    if ctx != nil:
      ctx.close()

registerPlugin("github-codeowners", GithubCodeOwner())
