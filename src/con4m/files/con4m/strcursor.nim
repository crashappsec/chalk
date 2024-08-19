# I was using a Stream abstraction here, but streams won't marshall
# and we will need them to to be able to support suspension and
# resumption.
#
# Plus, I'd prefer to keep UTF32 instead of UTF8.
import unicode, types

proc newStringCursor*(s: string): StringCursor =
  result = StringCursor(runes: s.toRunes(), i: 0)

template peek*(cursor: StringCursor): Rune =
  if cursor.i >= cursor.runes.len():
    Rune(0)
  else:
    cursor.runes[cursor.i]

proc read*(cursor: StringCursor): Rune =
  if cursor.i >= cursor.runes.len():
    return Rune(0)
  else:
    result = cursor.runes[cursor.i]
    cursor.i += result.size()

template advance*(cursor: StringCursor) =
  cursor.i += 1

template getPosition*(cursor: StringCursor): int = cursor.i

proc setPosition*(cursor: StringCursor, i: int) =
  cursor.i = i

template slice*(cursor: StringCursor, startIx, endIx: int): seq[Rune] =
  cursor.runes[startIx ..< endIx]
