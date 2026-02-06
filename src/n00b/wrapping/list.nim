import ".."/[
  types,
]
from "."/string import `$`

export types

proc n00b_list_len(
  list: ptr n00b_list_t,
): n00b_size_t {.header:"n00b/adts.h".}

proc n00b_list_set(
  list:  ptr n00b_list_t,
  index: n00b_index_t,
  item:  pointer,
): bool {.header:"n00b/adts.h".}

proc n00b_list_get(
  list:  ptr n00b_list_t,
  index: n00b_index_t,
  found: ptr bool,
): pointer {.header:"n00b/adts.h", importc:"_n00b_list_get".}

proc n00b_list_contains(
  list: ptr n00b_list_t,
  item: pointer,
): bool {.header:"n00b/adts.h".}

proc len*(list: ptr n00b_list_t): int =
  if list == nil:
    return 0
  return int(n00b_list_len(list))

proc `[]`*(list: ptr n00b_list_t, index: int): pointer =
  return n00b_list_get(list, n00b_index_t(index), nil)

proc `[]=`*(list: ptr n00b_list_t, index: int, value: pointer) =
  if list == nil:
    raise newException(ValueError, "list is nil")
  discard n00b_list_set(list, n00b_index_t(index), value)

proc contains*(list: ptr n00b_list_t, value: pointer): bool =
  if list == nil:
    return false
  return n00b_list_contains(list, value)

iterator items*(list: ptr n00b_list_t): pointer =
  if list != nil:
    let count = len(list)
    for i in 0 ..< count:
      yield list[i]

proc `$`*(list: ptr n00b_list_t): seq[string] =
  result = @[]
  if list == nil:
    return
  for item in list:
    let strItem = cast[ptr n00b_string_t](item)
    if strItem != nil:
      result.add($strItem)
