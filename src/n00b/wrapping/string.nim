import ".."/[
  types,
]
import "."/[
  macros,
]

export types

proc n00b_cstring(
  s:   cstring,
  loc: cstring,
): ptr n00b_string_t {.header:"n00b/text.h",
                      importc:"_n00b_cstring".}

proc n00b_from_cstr_list(
  l: cstringArray,
  n: n00b_size_t,
): ptr n00b_list_t {.header:"n00b/adts.h".}

proc n00b_string_to_cstr(
  s: ptr n00b_string_t,
): cstring {.header:"n00b/adts.h".}

proc n00b_buffer_to_c(
  b: ptr n00b_buf_t,
  n: ptr int64,
): cstring {.header:"n00b/adts.h"}

proc `@`*(s: string): ptr n00b_string_t =
  return n00b_cstring(cstring(s), n00bLoc())

proc `@`*(s: seq[string]): ptr n00b_list_t =
  let p = allocCStringArray(s)
  result = n00b_from_cstr_list(p, n00b_size_t(len(s)))
  deallocCStringArray(p)

proc `$`*(s: ptr n00b_string_t): string =
  return $(n00b_string_to_cstr(s))

proc `$`*(b: ptr n00b_buf_t): string =
  return $(n00b_buffer_to_c(b, nil))
