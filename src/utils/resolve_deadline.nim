import std/[strutils]

{.compile: "resolve_deadline.c".}

proc resolveDeadline(host, service: cstring, timeoutMs: cint, status: ptr cint): cstring
  {.importc: "chalk_resolve_deadline", cdecl.}
proc freeAddresses(addresses: cstring) {.importc: "chalk_resolve_free", cdecl.}

type ResolutionTimeoutError* = object of CatchableError

proc resolveWithin*(host, service: string, timeoutMs: int): seq[string] =
  var status: cint
  let addresses = resolveDeadline(host.cstring, service.cstring, cint(timeoutMs), addr status)
  try:
    case status
    of 0:
      for address in ($addresses).splitLines():
        if address != "" and address notin result:
          result.add(address)
    of 2:
      raise newException(ResolutionTimeoutError, "DNS resolution timed out")
    else:
      raise newException(IOError, "registry hostname could not be resolved")
  finally:
    if addresses != nil:
      freeAddresses(addresses)
