import pkg/[
  nimutils/box,
]
import "../.."/[
  utils/chalkdict,
]
import ".."/[
  types,
]
import "."/[
  list,
  string,
  tuples,
]

export types

proc n00b_dict_get(
  dict:  ptr n00b_dict_t,
  key:   N00bPrimitives,
  found: ptr bool,
): N00bPrimitive {.header:"n00b/adts.h", importc:"_n00b_dict_get".}

proc n00b_dict_put(
  dict:  ptr n00b_dict_t,
  key:   N00bPrimitives,
  value: N00bPrimitives,
): pointer {.header:"n00b/adts.h", importc:"_n00b_dict_put".}

proc n00b_dict_len(
  dict: ptr n00b_dict_t,
): n00b_size_t {.header:"n00b/adts.h".}

proc n00b_dict_contains(
  dict: ptr n00b_dict_t,
  key:  N00bPrimitives,
): bool {.header:"n00b/adts.h".}

proc n00b_dict_remove(
  dict: ptr n00b_dict_t,
  key:  N00bPrimitives,
): bool {.header:"n00b/adts.h", importc:"_n00b_dict_remove".}

proc n00b_dict_items(
  dict: ptr n00b_dict_t,
  args: ptr n00b_karg_info_t,
): ptr n00b_list_t {.header:"n00b/adts.h", importc:"_n00b_dict_items".}

proc len*(dict: ptr n00b_dict_t): int =
  if dict == nil:
    return 0
  return int(n00b_dict_len(dict))

proc `[]`*(dict: ptr n00b_dict_t, key: N00bPrimitives): N00bPrimitive =
  if dict == nil:
    raise newException(ValueError, "dict is nil")
  var found: bool
  result = n00b_dict_get(dict, key, addr found)
  if not found:
    raise newException(KeyError, "key is not in the dict")

proc `[]=`*(dict: ptr n00b_dict_t, key: N00bPrimitives, value: N00bPrimitives) =
  if dict == nil:
    raise newException(ValueError, "dict is nil")
  discard n00b_dict_put(dict, key, value)

proc contains*(dict: ptr n00b_dict_t, key: N00bPrimitives): bool =
  if dict == nil:
    return false
  return n00b_dict_contains(dict, key)

proc del*(dict: ptr n00b_dict_t, key: N00bPrimitives) =
  if dict == nil:
    raise newException(ValueError, "dict is nil")
  discard n00b_dict_remove(dict, key)

iterator pairs*(dict: ptr n00b_dict_t): (N00bPrimitive, N00bPrimitive) =
  if dict != nil:
    for item in n00b_dict_items(dict, nil):
      let itemTuple = cast[ptr n00b_tuple_t](item)
      if itemTuple == nil:
        continue
      let
        key = itemTuple[0]
        val = itemTuple[1]
      if key == nil or val == nil:
        continue
      yield (key, val)

iterator keys*(dict: ptr n00b_dict_t): N00bPrimitive =
  for key, _ in dict.pairs():
    yield key

iterator values*(dict: ptr n00b_dict_t): N00bPrimitive =
  for _, value in dict.pairs():
    yield value

proc `$`*(dict: ptr n00b_dict_t): ChalkDict =
  result = ChalkDict()
  if dict == nil:
    return
  for key, val in dict:
    if not key.isString():
      continue
    let dictKey = $key.asString()
    if val.isString():
      result[dictKey] = pack($val.asString())
    elif val.isList():
      result[dictKey] = pack($val.asList())
    elif val.isDict():
      result[dictKey] = pack($val.asDict())
    elif val.isBool():
      result[dictKey] = pack(val.asBool())
    elif val.isInt():
      result[dictKey] = pack(val.asInt64())
