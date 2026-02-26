import std/[
  options,
  paths,
  posix,
  re,
]
import pkg/[
  nimutils,
]
import "."/[
  strings,
  tables,
]

type
  ProcStringTable*      = TableRef[string, string]
  ProcStringArrayTable* = seq[seq[string]]

proc loadStringArrayTable*(path: Path): Option[ProcStringArrayTable] =
  ## Load proc files that are excel-style tables which are sequences of strings
  let contents = tryToLoadFile(path.string)
  if contents == "":
    return none(ProcStringArrayTable)
  var res = newSeq[seq[string]]()
  for line in contents.splitLines[1..^1]:
    res.add(re.split(line, re"[\s]+"))
  return some(res)

proc loadStringTable*(path: Path | string): Option[ProcStringTable] =
  ## Load proc files that are in key/value pair format, one per line.
  let contents = tryToLoadFile(string(path))
  if contents == "":
    return none(ProcStringTable)
  let lines = contents.split('\n')
  var res   = ProcStringTable()
  for line in lines:
    let ix = line.find(':')
    if ix == -1:
      continue
    res[line[0 ..< ix].strip()] = line[ix + 1 .. ^1].strip()
  return some(res)
