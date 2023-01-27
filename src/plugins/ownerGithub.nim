## Looks for and parses github CODEOWNERS files.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, streams, strutils, strformat, os, glob
import nimutils, ../config, ../plugins


const
  fNameGHCO = "CODEOWNERS"
  dirGH     = ".github"
  dirDoc    = "docs"
  eCantOpen = "{fname}: File found, but could not be read"
  eFileOpen = "{filename}: Could not open file."

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

proc findCodeOwner(contents, artifactPath, copath: string): string =
  assert artifactPath.startsWith(copath)

  let
    lines   = contents.split("\n")
    gitdir  = copath.splitPath().head
    relPath = artifactPath[len(copath) .. ^1]
    path    = if relpath.startsWith("/"): relpath else: "/" & relPath

  for line in lines:
    let cur = line.strip()

    if cur == "" or cur[0] == '#':
      continue

    let ix = cur.find(' ')
    if ix == -1: continue
    var
      txt = cur[0 ..< ix].strip()

    if not txt.startsWith("/"):
      txt = "**/" & txt
    if txt.endsWith("/"):
      txt &= "**"
    let
      pattern = glob(txt)
      owners = line[ix+1 .. ^1].strip()


    if path.matches(pattern):
      result = owners
      # Keep going; the last match is the most specific and wins.

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
      error(eFileOpen)
    else:
      let
        s = ctx.readAll()
        m = s.findCodeOwner(sami.fullPath, fname.splitPath().head)

      if m != "":
        result["CODE_OWNERS"] = pack(m)
  except:
    error(eCantOpen.fmt())
  finally:
    if ctx != nil:
      ctx.close()

registerPlugin("github_codeowners", GithubCodeOwner())
