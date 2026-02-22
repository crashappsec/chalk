import std/[
  posix,
]
import "../.."/[
  utils/times,
]
import ".."/[
  types,
]
import "."/[
  string,
]

export types

proc n00b_timeval_to_duration(
  t: ptr Timeval,
): ptr n00b_duration_t {.header:"n00b/adts.h".}

proc n00b_to_string(
  t: ptr n00b_duration_t,
): ptr n00b_string_t {.header:"n00b.h"}

proc `$`*(d: ptr n00b_duration_t): string =
  return $n00b_to_string(d)

proc `@`*(d: Duration): ptr n00b_duration_t =
  let te =Timeval(
    tv_sec:  posix.Time(d.inSeconds()),
    # get remainder microseconds discounting seconds
    tv_usec: d.inMicroseconds() %% 1_000_000,
  )
  result = n00b_timeval_to_duration(addr(te))
