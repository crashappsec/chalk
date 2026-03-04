type
  n00b_ntype_t*       {.header:"n00b.h".} = uint64
  n00b_arena_t*       {.header:"n00b.h".} = object
  n00b_varargs_t*     {.header:"n00b.h".} = object
  n00b_karg_info_t*   {.header:"n00b.h".} = object
  n00b_list_t*        {.header:"n00b.h".} = object
  n00b_dict_t*        {.header:"n00b.h".} = object
  n00b_tuple_t*       {.header:"n00b.h".} = object
  n00b_string_t*      {.header:"n00b.h".} = object
  n00b_proc_t*        {.header:"n00b.h".} = object
  n00b_stream_t*      {.header:"n00b.h".} = object
  n00b_buf_t*         {.header:"n00b.h".} = object
  n00b_duration_t*    {.header:"n00b.h".} = object
  n00b_index_t*       {.header:"n00b.h".} = int64
  n00b_size_t*        {.header:"n00b.h".} = uint64
  n00bProc*                               = ptr n00b_proc_t

  N00bPrimitive*  = pointer
  N00bPrimitives* = (
    ptr n00b_list_t |
    ptr n00b_dict_t |
    ptr n00b_tuple_t |
    ptr n00b_string_t |
    ptr n00b_proc_t |
    ptr n00b_stream_t |
    ptr n00b_buf_t |
    ptr n00b_duration_t
  )

proc n00b_type_string*():   n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_list*():     n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_dict*():     n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_tuple*():    n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_buffer*():   n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_duration*(): n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_stream*():   n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_type_process*():  n00b_ntype_t {.header:"n00b/core.h".}

proc n00b_type_is_string*(typeId: n00b_ntype_t):   bool {.header:"n00b/core.h".}
proc n00b_type_is_bool*(typeId: n00b_ntype_t):     bool {.header:"n00b/core.h".}
proc n00b_type_is_int_type*(typeId: n00b_ntype_t): bool {.header:"n00b/core.h".}
proc n00b_type_is_box*(typeId: n00b_ntype_t):      bool {.header:"n00b/core.h".}
proc n00b_type_is_list*(typeId: n00b_ntype_t):     bool {.header:"n00b/core.h".}
proc n00b_type_is_dict*(typeId: n00b_ntype_t):     bool {.header:"n00b/core.h".}
proc n00b_type_is_tuple*(typeId: n00b_ntype_t):    bool {.header:"n00b/core.h".}
proc n00b_type_is_buffer*(typeId: n00b_ntype_t):   bool {.header:"n00b/core.h".}
proc n00b_type_is_duration*(typeId: n00b_ntype_t): bool {.header:"n00b/core.h".}
proc n00b_type_is_stream*(typeId: n00b_ntype_t):   bool {.header:"n00b/core.h".}
proc n00b_type_is_process*(typeId: n00b_ntype_t):  bool {.header:"n00b/core.h".}
proc n00b_type_unbox*(typeId: n00b_ntype_t):       n00b_ntype_t {.header:"n00b/core.h".}

proc n00b_get_my_type*(obj: pointer): n00b_ntype_t {.header:"n00b/core.h".}
proc n00b_unbox*(obj: N00bPrimitive): int64 {.header:"n00b/adts.h".}

proc normalizedType*(typeId: n00b_ntype_t): n00b_ntype_t =
  if n00b_type_is_box(typeId):
    return n00b_type_unbox(typeId)
  return typeId

proc n00bType*(obj: N00bPrimitive): n00b_ntype_t =
  if obj == nil:
    return n00b_ntype_t(0)
  return n00b_get_my_type(obj)

proc isStringType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_string(typeId)
proc isString*(x: N00bPrimitive): bool =
  return x.n00bType().isStringType()

proc isBoolType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_bool(typeId.normalizedType())
proc isBool*(x: N00bPrimitive): bool =
  return x.n00bType().isBoolType()

proc isIntType*(typeId: n00b_ntype_t): bool =
  let unboxed = typeId.normalizedType()
  return n00b_type_is_int_type(unboxed) and not n00b_type_is_bool(unboxed)
proc isInt*(x: N00bPrimitive): bool =
  return x.n00bType().isIntType()

proc isListType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_list(typeId)
proc isList*(x: N00bPrimitive): bool =
  return x.n00bType().isListType()

proc isDictType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_dict(typeId)
proc isDict*(x: N00bPrimitive): bool =
  return x.n00bType().isDictType()

proc isTupleType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_tuple(typeId)
proc isTuple*(x: N00bPrimitive): bool =
  return x.n00bType().isTupleType()

proc isBufferType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_buffer(typeId)
proc isBuffer*(x: N00bPrimitive): bool =
  return x.n00bType().isBufferType()

proc isDurationType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_duration(typeId)
proc isDuration*(x: N00bPrimitive): bool =
  return x.n00bType().isDurationType()

proc isStreamType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_stream(typeId)
proc isStream*(x: N00bPrimitive): bool =
  return x.n00bType().isStreamType()

proc isProcessType*(typeId: n00b_ntype_t): bool =
  return n00b_type_is_process(typeId)
proc isProcess*(x: N00bPrimitive): bool =
  return x.n00bType().isProcessType()

proc asString*(x: N00bPrimitive): ptr n00b_string_t =
  if not x.isString():
    raise newException(ValueError, "not a string")
  return cast[ptr n00b_string_t](x)

proc asList*(x: N00bPrimitive): ptr n00b_list_t =
  if not x.isList():
    raise newException(ValueError, "not a list")
  return cast[ptr n00b_list_t](x)

proc asDict*(x: N00bPrimitive): ptr n00b_dict_t =
  if not x.isDict():
    raise newException(ValueError, "not a dict")
  return cast[ptr n00b_dict_t](x)

proc asBool*(x: N00bPrimitive): bool =
  if not x.isBool():
    raise newException(ValueError, "not a bool")
  return n00b_unbox(x) != 0

proc asInt64*(x: N00bPrimitive): int64 =
  if not x.isInt():
    raise newException(ValueError, "not an int")
  return n00b_unbox(x)
