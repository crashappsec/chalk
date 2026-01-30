import ".."/[
  types,
]

export types

proc n00b_list_len(
  list: ptr n00b_list_t,
): n00b_size_t {.header:"n00b/adts.h".}

proc n00b_list_get(
  list:  ptr n00b_list_t,
  index: n00b_index_t,
  found: ptr bool,
): pointer {.header:"n00b/adts.h", importc:"_n00b_list_get".}

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

proc n00b_resolve_and_unbox(
  obj: pointer,
): int64 {.header:"n00b/adts.h".}

proc listLen*(list: ptr n00b_list_t): int =
  if list == nil:
    return 0
  return int(n00b_list_len(list))

proc listGet*(list: ptr n00b_list_t, index: int): pointer =
  return n00b_list_get(list, n00b_index_t(index), nil)

proc dictItems*(dict: ptr n00b_dict_t): ptr n00b_list_t =
  if dict == nil:
    return nil
  return n00b_dict_items(dict, nil)

proc tupleGet*(tpl: ptr n00b_tuple_t, index: int): pointer =
  if tpl == nil:
    return nil
  return n00b_tuple_get(tpl, int64(index))

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

proc unboxInt*(obj: pointer): int64 =
  if obj == nil:
    return 0
  return n00b_resolve_and_unbox(obj)
