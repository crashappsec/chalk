import "."/[
  types,
  wrapping/string,
]

proc n00b_stdin*(): ptr n00b_stream_t {.header:"n00b/io.h".}
proc n00b_stdout*(): ptr n00b_stream_t {.header:"n00b/io.h".}

proc n00b_stream_read(
  stream: ptr n00b_stream_t,
  timeout: cint,
  err: pointer, # ptr bool
): ptr n00b_buf_t {.header:"n00b/io.h".}

proc n00b_print(
  stream: ptr n00b_stream_t,
  data: ptr n00b_string_t,
) {.varargs, header:"n00b/io.h".}

proc readAll*(stream: ptr n00b_stream_t): string =
  return $n00b_stream_read(stream, cint(0), nil)

proc n00bPrint*(stream: ptr n00b_stream_t, s: string) =
  n00b_print(stream, @s)
