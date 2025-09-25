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
): n00b_duration_t {.header:"n00b.h".}

proc n00b_to_string(
  t: n00b_duration_t,
): n00b_string_t {.header:"n00b.h"}

proc `$`*(d: n00b_duration_t): string =
  return $n00b_to_string(d)

proc `@`*(d: Duration): n00b_duration_t =
  let te =Timeval(
    tv_sec:  posix.Time(d.inSeconds()),
    # get remainder microseconds discounting seconds
    tv_usec: d.inMicroseconds() %% 1_000_000,
  )
  result = n00b_timeval_to_duration(addr(te))
