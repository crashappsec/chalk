import ".."/[
  types,
]

export types

type
  n00b_kw_value* = uint64

type n00bOneKwarg = tuple
  key:   cstring
  value: n00b_kw_value

proc n00b_pass_kargs(
  num: cint,
): n00b_karg_t {.varargs,
                 header:"n00b.h".}

template n00bKwargs*(
  kw1:   n00bOneKwarg,
): n00b_karg_t =
  n00b_pass_kargs(
    2,
    kw1.key,
    kw1.value,
  )

template n00bKwargs*(
  kw1:   n00bOneKwarg,
  kw2:   n00bOneKwarg,
): n00b_karg_t =
  n00b_pass_kargs(
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
): n00b_karg_t =
  n00b_pass_kargs(
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
): n00b_karg_t =
  n00b_pass_kargs(
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

template n00bKw*(
  k: string,
  v: typeof(nil) |
     n00b_duration_t |
     n00b_string_t |
     cstring,
): n00bOneKwarg =
  (cstring(k), cast[n00b_kw_value](v))

template n00bKw*(
  k: string,
  v: bool,
): n00bOneKwarg =
  (cstring(k), n00b_kw_value(v))
