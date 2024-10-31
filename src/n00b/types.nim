type
  n00b_type_t*     = distinct pointer
  n00b_karg_t*     = distinct pointer
  n00b_list_t*     = distinct pointer
  n00b_string_t*   = distinct pointer
  n00b_proc_t*     = distinct pointer
  n00b_buf_t*      = distinct pointer
  n00b_duration_t* = distinct pointer

proc n00b_type_string*():   n00b_type_t {.header:"n00b.h".}
proc n00b_type_duration*(): n00b_type_t {.header:"n00b.h".}
