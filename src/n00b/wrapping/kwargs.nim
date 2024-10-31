import ".."/[
  types,
]

export types

type
  n00bKwValue* = pointer
  n00bOneKwarg = tuple
    key:   cstring
    value: n00bKwValue

template n00bKw*(
  k: string,
  v: typeof(nil) |
     ptr n00b_duration_t |
     ptr n00b_string_t |
     ptr n00b_list_t |
     cstring,
): n00bOneKwarg =
  (cstring(k), cast[n00bKwValue](v))

template n00bKw*(
  k: string,
  v: bool,
): n00bOneKwarg =
  (cstring(k), cast[n00bKwValue](uint64(v)))

proc alloca(size: csize_t): pointer {.importc,
                                     header: "<alloca.h>".}

proc n00b_kargs_setup(
  ska:   ptr n00b_karg_info_t,
  count: uint32,
): ptr n00b_karg_info_t {.varargs,
                         header:"n00b.h",
                         importc:"_n00b_kargs_setup".}

template call_n00b_kargs_obj(
  count: uint32,
  args:  varargs[untyped],
): ptr n00b_karg_info_t =
  let ska = cast[ptr n00b_karg_info_t](alloca(csize_t(
    sizeof(n00b_karg_info_t) +
    sizeof(nil) * count
  )))
  n00b_kargs_setup(
    ska,
    count,
    args,
  )

# in nim there is no way to pass varargs from nim to C
# so we duplicate all function signatures... :shrug:
template n00bKwargs*(
  kw1:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    2,
    kw1.key,
    kw1.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    4,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    6,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    8,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    10,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
  kw6:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    12,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
    kw6.key,
    kw6.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
  kw6:   n00bOneKwarg,
  kw7:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    14,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
    kw6.key,
    kw6.value,
    kw7.key,
    kw7.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
  kw6:   n00bOneKwarg,
  kw7:   n00bOneKwarg,
  kw8:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    16,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
    kw6.key,
    kw6.value,
    kw7.key,
    kw7.value,
    kw8.key,
    kw8.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
  kw6:   n00bOneKwarg,
  kw7:   n00bOneKwarg,
  kw8:   n00bOneKwarg,
  kw9:   n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    18,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
    kw6.key,
    kw6.value,
    kw7.key,
    kw7.value,
    kw8.key,
    kw8.value,
    kw9.key,
    kw9.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
  kw3:   n00bOneKwarg,
  kw4:   n00bOneKwarg,
  kw5:   n00bOneKwarg,
  kw6:   n00bOneKwarg,
  kw7:   n00bOneKwarg,
  kw8:   n00bOneKwarg,
  kw9:   n00bOneKwarg,
  kw10:  n00bOneKwarg,
): ptr n00b_karg_info_t =
  call_n00b_kargs_obj(
    20,
    kw1.key,
    kw1.value,
    kw2.key,
    kw2.value,
    kw3.key,
    kw3.value,
    kw4.key,
    kw4.value,
    kw5.key,
    kw5.value,
    kw6.key,
    kw6.value,
    kw7.key,
    kw7.value,
    kw8.key,
    kw8.value,
    kw9.key,
    kw9.value,
    kw10.key,
    kw10.value,
  )
