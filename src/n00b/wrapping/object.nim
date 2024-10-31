import ".."/[
  types,
]

export types

let n00b_default_heap {.header:"n00b.h".}: pointer

proc n00b_new(
  heap: pointer,
  file: cstring,
  lint: cint,
  t:    n00b_type_t,
): pointer {.varargs,
             header:"n00b.h",
             importc:"_n00b_new".}

proc n00bNew*(t: n00b_type_t): pointer =
  # TODO switch to nim macro to pass nims correct file and line
  result = n00b_new(n00b_default_heap, "nim", 1, t, 0)
