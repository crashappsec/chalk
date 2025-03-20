import ./[types, c]

proc `@`*(s: string): n00b_string_t =
  return n00b_cstring(s)

proc `@`*(s: seq[string]): n00b_list_t =
  let p = allocCStringArray(s)
  result = n00b_from_cstr_list(p, len(s))
  deallocCStringArray(p)

proc `$`*(b: n00b_buf_t): string =
  return $(n00b_buffer_to_c(b, nil))
