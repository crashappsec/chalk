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

proc n00b_type_string*():   n00b_ntype_t {.header:"n00b.h".}
proc n00b_type_duration*(): n00b_ntype_t {.header:"n00b.h".}
proc n00b_type_process*():  n00b_ntype_t {.header:"n00b.h".}
