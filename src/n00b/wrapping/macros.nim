template n00bLoc*(): cstring =
  let (filename, line, column) = instantiationInfo()
  cstring(filename & ":" & $line & ":" & $column)
