##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

when hostOs == "linux":
  import std/[
    nativesockets,
    net,
    options,
    os,
    oserrors,
    posix,
  ]

  # allow to use this as standalone module for testing without chalk imports
  when isMainModule:
    proc trace(s: string) =
      echo(s)
  else:
    import "."/[config]

  const
    msec           = 1000
    defaultTimeout = 5

  # these dont seem to be in stdlib?
  let
    MSG_ERRQUEUE      {.importc, header: "<sys/socket.h>".}:    int32
    MSG_DONTWAIT      {.importc, header: "<sys/socket.h>".}:    int32
    IPPROTO_IP        {.importc, header: "<netinet/in.h>".}:    int
    IP_TTL            {.importc, header: "<netinet/in.h>".}:    int
    IP_MULTICAST_TTL  {.importc, header: "<netinet/in.h>".}:    int
    IP_RECVERR        {.importc, header: "<netinet/in.h>".}:    int
    IP_RECVTTL        {.importc, header: "<netinet/in.h>".}:    int
    IP_RECVOPTS       {.importc, header: "<netinet/in.h>".}:    int
    SO_SNDTIMEO       {.importc, header: "<netinet/in.h>".}:    cint
    SO_RCVTIMEO       {.importc, header: "<netinet/in.h>".}:    cint
    SO_EE_ORIGIN_ICMP {.importc, header: "<linux/errqueue.h>"}: uint8

  type
    SockExtendedErr {.importc: "struct sock_extended_err", header: "<linux/errqueue.h>".} = object
      ee_errno:  uint32
      ee_origin: uint8
      ee_type:   uint8
      ee_code:   uint8
      ee_pad:    uint8
      ee_info:   ptr uint32
      ee_data:   ptr uint32
    IcmpType = enum
      EchoReply    = 0'u8
      Unreachable  = 3'u8
      EchoRequest  = 8'u8
      TTLExceeded  = 11'u8
    EchoRequestCode = enum
      Ping         = 0'u8
    IcmpPing = ref object
      icmptype*:   IcmpType
      icmpcode*:   EchoRequestCode
      checksum*:   uint16
      identifier*: uint16
      sequence*:   uint16

  proc SO_EE_OFFENDER(err: ptr SockExtendedErr):
    ptr Sockaddr {.importc, header: "<linux/errqueue.h>".}

  proc computeChecksum(x: openArray[uint8]): uint16 =
    ## https://www.rfc-editor.org/rfc/rfc792
    ## https://www.rfc-editor.org/rfc/rfc1071
    ## The checksum is the 16-bit ones's complement of the one's
    ## complement sum of the ICMP message starting with the ICMP Type.
    ## For computing the checksum , the checksum field should be zero.
    ## If the total length is odd, the received data is padded with one
    ## octet of zeros for computing the checksum.  This checksum may be
    ## replaced in the future.
    var
      sum: uint32 = 0
      i           = 0
      l           = len(x) - 1
    while i < l:
      # sum is 16-bit word whereas input is seq of 8-bit ints
      # hence shift left 8 to align bytes
      sum += (x[i] shl 8) + x[i + 1]
      i += 2
    # input is odd length - add last byte
    if i < len(x):
      sum += x[i] shl 8
    # convert to 16-bit by adding carry to sum
    while (sum shr 16) > 0:
      sum = (sum and 0xffff) + (sum shr 16)
    result = not result

  proc asArray(self: IcmpPing): array[8, uint8] =
    return cast[ptr array[sizeof(self), uint8]](self)[]

  proc asData(self: IcmpPing): string =
    for i in self.asArray():
      result.add(cast[char](i))

  proc setChecksum(self: IcmpPing): IcmpPing =
    self.checksum = computeChecksum(self.asArray())
    return self

  proc sendTo(handle: SocketHandle, data: string, dest: IpAddress, port = Port(0)) =
    # sending icmp packet requires native sockets which dont have easy API
    # like sockets do in stdlib hence more data dances here
    # which is mostly a copy from stdlib sendTo function
    var
      sockAddr: Sockaddr_storage
      sockLen:  SockLen
    toSockAddr(dest, port, sockAddr, sockLen)
    let sent = handle.sendto(
      cstring(data),
      cint(len(data)),
      cint(0'i32),
      cast[ptr SockAddr](addr sockAddr),
      sockLen,
    )
    if sent < 0:
      raiseOSError(osLastError())

  proc recvIp(handle: SocketHandle, dest: IpAddress): IpAddress =
    const length = 256
    var
      control: array[length, char]
      msg      = Tmsghdr(
        msg_control: addr(control),
        msg_controllen: length,
      )
      received = handle.recvmsg(addr(msg), 0'i32)
    if received >= 0:
      return dest
    let
      lastError    = osLastError()
      lastErrorMsg = osErrorMsg(lastError)
    if int32(lastError) != EHOSTUNREACH:
      trace("pingttl: unsupported errno " & $lastError & " - " & lastErrorMsg)
      raiseOSError(lastError)
    received = handle.recvmsg(addr(msg), MSG_ERRQUEUE or MSG_DONTWAIT)
    if received < 0:
      let
        e = osLastError()
        m = osErrorMsg(e)
      trace("pingttl: could not get errqueue " & $e & " - " & m)
      raiseOSError(lastError)
    if msg.msg_controllen == 0:
      trace("pingttl: errqueue control msg is empty")
      raiseOSError(lastError)
    var cmsg = CMSG_FIRSTHDR(addr(msg))
    while cmsg != nil:
      # https://www.man7.org/linux/man-pages/man7/ip.7.html
      # > Enable extended reliable error message passing.  When
      # > enabled on a datagram socket, all generated errors will be
      # > queued in a per-socket error queue.  When the user
      # > receives an error from a socket operation, the errors can
      # > be received by calling recvmsg(2) with the MSG_ERRQUEUE
      # > flag set.  The sock_extended_err structure describing the
      # > error will be passed in an ancillary message with the type
      # > IP_RECVERR and the level IPPROTO_IP.  This is useful for
      # > reliable error handling on unconnected sockets.  The
      # > received data portion of the error queue contains the
      # > error packet.
      if cmsg.cmsg_len   > 0 and
         cmsg.cmsg_level == IPPROTO_IP and
         cmsg.cmsg_type  == IP_RECVERR:
        let err = cast[ptr SockExtendedErr](CMSG_DATA(cmsg))
        if err.ee_origin != SO_EE_ORIGIN_ICMP:
          # this can be either icmp6 or local errors
          trace("pingttl: control message error origin is not icmp error " & $err.ee_origin)
          raiseOSError(lastError)
        if (err.ee_type != uint8(IcmpType.Unreachable) and
            err.ee_type != uint8(IcmpType.TTLExceeded)):
          trace("pingttl: control message icmp type is neither unreachable or ttl exceeded " & $err.ee_type)
          raiseOSError(lastError)
        # https://www.man7.org/linux/man-pages/man7/ip.7.html
        # > ee_errno contains the errno number of the queued error.
        # > ee_origin is the origin code of where the error
        # > originated.  The other fields are protocol-specific.  The
        # > macro SO_EE_OFFENDER returns a pointer to the address of
        # > the network object where the error originated from given a
        # > pointer to the ancillary message.  If this address is not
        # > known, the sa_family member of the sockaddr contains
        # > AF_UNSPEC and the other fields of the sockaddr are
        # > undefined.
        let offender = SO_EE_OFFENDER(err)
        if int32(offender.sa_family) == posix.AF_UNSPEC:
          trace("pingttl: icmp error from unknown offender source address family " & $offender.sa_family)
          raiseOSError(lastError)
        if int32(offender.sa_family) != posix.AF_INET:
          trace("pingttl: icmp error from unsupported offender source address family " & $offender.sa_family)
          raiseOSError(lastError)
        # TODO how to get the sock len directly from the sockaddr structure?
        # var
        #   address: IpAddress
        #   port:    Port
        # fromSockAddr(cast[ptr Sockaddr_in](offender)[], ???, address, port)
        let address = cast[ptr Sockaddr_in](offender)
        return parseIpAddress($(inet_ntoa(address.sin_addr)))
      cmsg = CMSG_NXTHDR(addr(msg), cmsg)
    raiseOSError(lastError)

  proc getIpForTTL*(dest:     IpAddress,
                    ttl:      int,
                    sequence  = 0,
                    timeoutMs = defaultTimeout): IpAddress =
    trace("pingttl: dest=" & $dest & " ttl=" & $ttl & " timeout=" & $timeoutMs)
    let
      id   = uint16(getpid())
      ping = IcmpPing(
        icmptype:   IcmpType.EchoRequest,
        icmpcode:   EchoRequestCode.Ping,
        checksum:   0'u16, # initial dummy checksum
        identifier: id,
        sequence:   uint16(sequence),
      ).setChecksum()
      data = ping.asData()
      handle = createNativeSocket(posix.AF_INET, posix.SOCK_DGRAM, posix.IPPROTO_ICMP)
    defer: handle.close()
    handle.setSockOptInt(IPPROTO_IP, IP_TTL,           ttl)
    handle.setSockOptInt(IPPROTO_IP, IP_MULTICAST_TTL, ttl)
    handle.setSockOptInt(IPPROTO_IP, IP_RECVTTL,       1)
    handle.setSockOptInt(IPPROTO_IP, IP_RECVERR,       1)
    handle.setSockOptInt(IPPROTO_IP, IP_RECVOPTS,      1)
    let timeout = Timeval(tv_sec: Time(0), tv_usec: Suseconds(timeoutMs * msec))
    discard handle.setsockopt(SOL_SOCKET, SO_SNDTIMEO, addr(timeout), SockLen(sizeof(timeout)))
    discard handle.setsockopt(SOL_SOCKET, SO_RCVTIMEO, addr(timeout), SockLen(sizeof(timeout)))
    handle.sendTo(data, dest)
    result = handle.recvIp(dest)

  proc tryGetIpForTTL*(dest:     IpAddress,
                       ttl:      int,
                       sequence  = 0,
                       timeoutMs = defaultTimeout): Option[IpAddress] =
    try:
      result = some(getIpForTTL(
        dest,
        ttl       = ttl,
        sequence  = sequence,
        timeoutMs = timeoutMs,
      ))
    except:
      return none(IpAddress)

  when isMainModule:
    import std/[cmdline, strutils]
    if paramCount() < 2:
      echo("usage: ", getAppFilename(), " <ip> <ttl>")
      quit(1)
    let
      ip  = parseIpAddress(paramStr(1))
      ttl = parseInt(paramStr(2))
    try:
      echo(getIpForTTL(ip, ttl = ttl))
    except:
      echo("could not determine TTL IP")

else:
  proc getIpForTTL*(dest:     IpAddress,
                    ttl:      int,
                    sequence  = 0,
                    timeoutMs = defaultTimeout): IpAddress =
    raise newException(AssertionError, "only implemented on linux")

  proc tryGetIpForTTL*(dest:     IpAddress,
                       ttl:      int,
                       sequence  = 0,
                       timeoutMs = defaultTimeout): Option[IpAddress] =
    raise newException(AssertionError, "only implemented on linux")
