import ".."/[
  types,
]

export types

proc n00b_cstring(
  s: cstring,
): n00b_string_t {.header:"n00b.h",
                   importc:"_n00b_cstring".}

proc n00b_from_cstr_list(
  l: pointer,
  n: int,
): n00b_list_t {.header:"n00b.h",stdcall.}

proc n00b_string_to_cstr(
  s: n00b_string_t,
): cstring {.header:"n00b.h".}

proc n00b_buffer_to_c(
  b: n00b_buf_t,
  n: ptr int,
): cstring {.header:"n00b.h"}

proc `@`*(s: string): n00b_string_t =
  return n00b_cstring(cstring(s))

proc `@`*(s: seq[string]): n00b_list_t =
  let p = allocCStringArray(s)
  result = n00b_from_cstr_list(p, len(s))
  deallocCStringArray(p)

proc `$`*(s: n00b_string_t): string =
  return $(n00b_string_to_cstr(s))

proc `$`*(b: n00b_buf_t): string =
  return $(n00b_buffer_to_c(b, nil))
