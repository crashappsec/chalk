import ./[types]

proc n00b_string_t*(): n00b_type_t {.header:"n00b.h".}

proc n00b_cstring*(
  s: cstring,
): n00b_string_t {.header:"n00b.h",
                   importc:"_n00b_cstring".}
proc n00b_c_map*(
  s: cstring,
): n00b_list_t {.varargs,
                 header:"n00b.h",
                 importc:"_n00b_c_map".}
proc n00b_from_cstr_list*(
  l: pointer,
  n: int,
): n00b_list_t {.header:"n00b.h",stdcall.}

proc n00b_buffer_to_c*(
  b: n00b_buf_t,
  n: ptr int,
): cstring {.header:"n00b.h"}

proc n00b_pass_kargs*(
  num: cint,
): n00b_karg_t {.varargs,
                 header:"n00b.h",
                 importc:"_n00b_pass_kargs".}

proc n00b_init*(
  argc: cint,
  argv: pointer,
  envp: pointer,
) {.header:"n00b.h".}

proc n00b_terminal_app_setup*() {.header:"n00b.h".}

proc n00b_run_process*(
  cmd: n00b_string_t,
  args: n00b_list_t,
  proxy: bool,
  capture: bool,
): n00b_proc_t {.varargs,
                 header:"n00b.h",
                 importc:"_n00b_run_process"}
proc n00b_proc_get_exit_code*(
  p: n00b_proc_t,
): cint {.header:"n00b.h"}
proc n00b_proc_get_stdin_capture*(
  p: n00b_proc_t,
): n00b_buf_t {.header:"n00b.h".}
proc n00b_proc_get_stdout_capture*(
  p: n00b_proc_t,
): n00b_buf_t {.header:"n00b.h".}
proc n00b_proc_get_stderr_capture*(
  p: n00b_proc_t,
): n00b_buf_t {.header:"n00b.h".}
