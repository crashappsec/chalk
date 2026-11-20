import std/[asyncdispatch, asyncnet, nativesockets, strutils]

{.compile: "resolve_deadline.c".}

proc resolveDeadline(host, service: cstring, timeoutMs: cint, status: ptr cint): cstring
  {.importc: "chalk_resolve_deadline", cdecl.}
proc freeAddresses(addresses: cstring) {.importc: "chalk_resolve_free", cdecl.}

type NetworkTimeoutError* = object of CatchableError

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
      raise newException(NetworkTimeoutError, "DNS resolution timed out")
    else:
      raise newException(IOError, "registry hostname could not be resolved")
  finally:
    if addresses != nil:
      freeAddresses(addresses)

proc connectNumeric(address: cstring, port: uint16, timeoutMs: cint, status: ptr cint): cint
  {.cdecl, importc: "chalk_connect_numeric".}

proc connectNumericWithin*(address: string, port: Port, timeoutMs: int): AsyncSocket =
  var status: cint
  let fd = connectNumeric(address.cstring, uint16(port), cint(timeoutMs), addr status)
  if status == 2:
    raise newException(NetworkTimeoutError, "registry connection timed out")
  if fd < 0:
    raise newException(IOError, "registry connection failed")
  let socket = AsyncFD(fd)
  try:
    register(socket)
    result = newAsyncSocket(socket,
      domain = (if ':' in address: AF_INET6 else: AF_INET),
      sockType = SOCK_STREAM, protocol = IPPROTO_TCP)
  except:
    socket.closeSocket()
    raise
