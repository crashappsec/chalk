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
  n00b_box_t*         {.header:"n00b.h".} = pointer
  n00bProc*                               = ptr n00b_proc_t

  N00bDictItemKind* = enum
    ndikBox
    ndikList
    ndikDict
    ndikTuple
    ndikString
    ndikProc
    ndikStream
    ndikBuf
    ndikDuration
    ndikUnknown

  N00bDictItem* = object
    case kind*: N00bDictItemKind
    of ndikBox:
      box*: n00b_box_t
    of ndikList:
      list*: ptr n00b_list_t
    of ndikDict:
      dict*: ptr n00b_dict_t
    of ndikTuple:
      tupleObj*: ptr n00b_tuple_t
    of ndikString:
      str*: ptr n00b_string_t
    of ndikProc:
      procObj*: ptr n00b_proc_t
    of ndikStream:
      stream*: ptr n00b_stream_t
    of ndikBuf:
      buf*: ptr n00b_buf_t
    of ndikDuration:
      duration*: ptr n00b_duration_t
    of ndikUnknown:
      raw*: pointer

proc n00b_type_string*():   n00b_ntype_t {.header:"n00b.h".}
proc n00b_type_duration*(): n00b_ntype_t {.header:"n00b.h".}
proc n00b_type_process*():  n00b_ntype_t {.header:"n00b.h".}
