import ".."/[
  types,
]
import "../.."/[
  utils/chalkdict,
]
import pkg/[
  nimutils/box,
]
import "."/list
from "."/string import `@`, `$`

export types

when defined(no_chalk):
  proc trace(s: string) =
    discard
else:
  import pkg/[
    nimutils/logging,
  ]

proc n00b_dict_get(
  dict:  ptr n00b_dict_t,
  key:   pointer,
  found: ptr bool,
): pointer {.header:"n00b/adts.h", importc:"_n00b_dict_get".}

proc n00b_dict_put(
  dict:  ptr n00b_dict_t,
  key:   pointer,
  value: pointer,
): pointer {.header:"n00b/adts.h", importc:"_n00b_dict_put".}

proc n00b_dict_len(
  dict: ptr n00b_dict_t,
): n00b_size_t {.header:"n00b/adts.h".}

proc n00b_dict_contains(
  dict: ptr n00b_dict_t,
  key:  pointer,
): bool {.header:"n00b/adts.h".}

proc n00b_dict_remove(
  dict: ptr n00b_dict_t,
  key:  pointer,
): bool {.header:"n00b/adts.h", importc:"_n00b_dict_remove".}

proc n00b_dict_items(
  dict: ptr n00b_dict_t,
  args: ptr n00b_karg_info_t,
): ptr n00b_list_t {.header:"n00b/adts.h", importc:"_n00b_dict_items".}

proc n00b_tuple_get(
  tpl: ptr n00b_tuple_t,
  index: int64,
): pointer {.header:"n00b/adts.h".}

proc n00b_get_my_type(
  obj: pointer,
): n00b_ntype_t {.header:"n00b/core.h".}

proc n00b_type_is_string(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_list(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_bool_box(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_int_box(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_dict(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_tuple(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_buffer(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_duration(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_stream(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_type_is_process(
  typeId: n00b_ntype_t,
): bool {.header:"n00b/core.h".}

proc n00b_resolve_and_unbox(
  obj: pointer,
): int64 {.header:"n00b/adts.h".}

proc rawPointer*(item: N00bDictItem): pointer =
  case item.kind
  of ndikBox:
    cast[pointer](item.box)
  of ndikList:
    cast[pointer](item.list)
  of ndikDict:
    cast[pointer](item.dict)
  of ndikTuple:
    cast[pointer](item.tupleObj)
  of ndikString:
    cast[pointer](item.str)
  of ndikProc:
    cast[pointer](item.procObj)
  of ndikStream:
    cast[pointer](item.stream)
  of ndikBuf:
    cast[pointer](item.buf)
  of ndikDuration:
    cast[pointer](item.duration)
  of ndikUnknown:
    item.raw

proc toDictItem*(item: N00bDictItem): N00bDictItem =
  item

proc toDictItem*(obj: ptr n00b_string_t): N00bDictItem =
  N00bDictItem(kind: ndikString, str: obj)

proc toDictItem*(obj: ptr n00b_list_t): N00bDictItem =
  N00bDictItem(kind: ndikList, list: obj)

proc toDictItem*(obj: ptr n00b_dict_t): N00bDictItem =
  N00bDictItem(kind: ndikDict, dict: obj)

proc toDictItem*(obj: ptr n00b_tuple_t): N00bDictItem =
  N00bDictItem(kind: ndikTuple, tupleObj: obj)

proc toDictItem*(obj: ptr n00b_proc_t): N00bDictItem =
  N00bDictItem(kind: ndikProc, procObj: obj)

proc toDictItem*(obj: ptr n00b_stream_t): N00bDictItem =
  N00bDictItem(kind: ndikStream, stream: obj)

proc toDictItem*(obj: ptr n00b_buf_t): N00bDictItem =
  N00bDictItem(kind: ndikBuf, buf: obj)

proc toDictItem*(obj: ptr n00b_duration_t): N00bDictItem =
  N00bDictItem(kind: ndikDuration, duration: obj)

proc toDictItem*(obj: string): N00bDictItem =
  toDictItem(@obj)

proc toDictItem*(obj: pointer): N00bDictItem =
  if obj == nil:
    return N00bDictItem(kind: ndikUnknown, raw: nil)

  let t = n00b_get_my_type(obj)
  if n00b_type_is_string(t):
    return N00bDictItem(kind: ndikString, str: cast[ptr n00b_string_t](obj))
  if n00b_type_is_list(t):
    return N00bDictItem(kind: ndikList, list: cast[ptr n00b_list_t](obj))
  if n00b_type_is_dict(t):
    return N00bDictItem(kind: ndikDict, dict: cast[ptr n00b_dict_t](obj))
  if n00b_type_is_tuple(t):
    return N00bDictItem(kind: ndikTuple, tupleObj: cast[ptr n00b_tuple_t](obj))
  if n00b_type_is_buffer(t):
    return N00bDictItem(kind: ndikBuf, buf: cast[ptr n00b_buf_t](obj))
  if n00b_type_is_duration(t):
    return N00bDictItem(kind: ndikDuration, duration: cast[ptr n00b_duration_t](obj))
  if n00b_type_is_stream(t):
    return N00bDictItem(kind: ndikStream, stream: cast[ptr n00b_stream_t](obj))
  if n00b_type_is_process(t):
    return N00bDictItem(kind: ndikProc, procObj: cast[ptr n00b_proc_t](obj))
  if n00b_type_is_bool_box(t) or n00b_type_is_int_box(t):
    return N00bDictItem(kind: ndikBox, box: cast[n00b_box_t](obj))

  return N00bDictItem(kind: ndikUnknown, raw: obj)

proc len*(dict: ptr n00b_dict_t): int =
  if dict == nil:
    return 0
  return int(n00b_dict_len(dict))

proc `[]`*(dict: ptr n00b_dict_t, key: N00bDictItem): N00bDictItem =
  if dict == nil:
    return N00bDictItem(kind: ndikUnknown, raw: nil)
  return toDictItem(n00b_dict_get(dict, rawPointer(key), nil))

proc `[]`*(dict: ptr n00b_dict_t, key: string): N00bDictItem =
  return dict[toDictItem(@key)]

proc `[]=`*(dict: ptr n00b_dict_t, key: N00bDictItem, value: N00bDictItem) =
  if dict == nil:
    raise newException(ValueError, "dict is nil")
  discard n00b_dict_put(dict, rawPointer(key), rawPointer(value))

proc `[]=`*(dict: ptr n00b_dict_t, key: string, value: N00bDictItem) =
  dict[toDictItem(@key)] = value

proc contains*(dict: ptr n00b_dict_t, key: N00bDictItem): bool =
  if dict == nil:
    return false
  return n00b_dict_contains(dict, rawPointer(key))

proc contains*(dict: ptr n00b_dict_t, key: string): bool =
  return dict.contains(toDictItem(@key))

proc del*(dict: ptr n00b_dict_t, key: N00bDictItem) =
  if dict == nil:
    raise newException(ValueError, "dict is nil")
  discard n00b_dict_remove(dict, rawPointer(key))

proc del*(dict: ptr n00b_dict_t, key: string) =
  dict.del(toDictItem(@key))

proc `[]`*(tpl: ptr n00b_tuple_t, index: int): pointer =
  if tpl == nil:
    return nil
  return n00b_tuple_get(tpl, int64(index))

iterator pairs*(dict: ptr n00b_dict_t): (N00bDictItem, N00bDictItem) =
  let items = if dict == nil: nil else: n00b_dict_items(dict, nil)
  if items != nil:
    for item in items:
      let itemTuple = cast[ptr n00b_tuple_t](item)
      if itemTuple == nil:
        continue
      let keyPtr = itemTuple[0]
      let valPtr = itemTuple[1]
      if keyPtr == nil or valPtr == nil:
        continue
      yield (toDictItem(keyPtr), toDictItem(valPtr))

iterator items*(dict: ptr n00b_dict_t): N00bDictItem =
  for _, value in dict.pairs():
    yield value

iterator keys*(dict: ptr n00b_dict_t): N00bDictItem =
  for key, _ in dict.pairs():
    yield key

iterator values*(dict: ptr n00b_dict_t): N00bDictItem =
  for _, value in dict.pairs():
    yield value

proc objType*(obj: pointer): n00b_ntype_t =
  if obj == nil:
    return n00b_ntype_t(0)
  return n00b_get_my_type(obj)

proc isStringType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_string(typeId)

proc isListType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_list(typeId)

proc isBoolBoxType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_bool_box(typeId)

proc isIntBoxType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_int_box(typeId)

proc isDictType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_dict(typeId)

proc unboxInt*(obj: pointer): int64 =
  if obj == nil:
    return 0
  return n00b_resolve_and_unbox(obj)

proc `$`*(dict: ptr n00b_dict_t): ChalkDict =
  result = ChalkDict()
  if dict == nil:
    return

  for keyPtr, valPtr in dict:
    let keyStrPtr = cast[ptr n00b_string_t](keyPtr.rawPointer())
    if keyStrPtr == nil:
      continue

    let key = $keyStrPtr
    let valuePtr = valPtr.rawPointer()
    let valueType = objType(valuePtr)
    if valueType.isStringType():
      result[key] = pack($(cast[ptr n00b_string_t](valuePtr)))
    elif valueType.isListType():
      result[key] = pack($(cast[ptr n00b_list_t](valuePtr)))
    elif valueType.isBoolBoxType():
      result[key] = pack(unboxInt(valuePtr) != 0)
    elif valueType.isIntBoxType():
      result[key] = pack(unboxInt(valuePtr))
    elif valueType.isDictType():
      result[key] = pack($(cast[ptr n00b_dict_t](valuePtr)))
    else:
      trace("n00b dict: unsupported value type for key=" & key & " type=" & $valueType)
