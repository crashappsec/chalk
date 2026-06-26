import ".."/[
  types,
]

export types

proc n00b_tuple_get(
  tpl: ptr n00b_tuple_t,
  index: int64,
): N00bPrimitive {.header:"n00b/adts.h".}

proc n00b_tuple_len(
  tpl: ptr n00b_tuple_t,
): n00b_size_t {.header:"n00b/adts.h".}

proc `[]`*(tpl: ptr n00b_tuple_t, index: int): N00bPrimitive =
  if tpl == nil:
    return nil
  return n00b_tuple_get(tpl, int64(index))

proc len*(tpl: ptr n00b_tuple_t): int =
  return int(n00b_tuple_len(tpl))
