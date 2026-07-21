import std/[
  nativesockets,
  net,
  posix,
  strutils,
]
import "../../src/utils/dns"

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

template checkRaises(exc: typedesc, body: untyped) =
  block:
    var raised = false
    try:
      body
    except exc:
      raised = true
    doAssert raised, "expected " & astToStr(exc) & " to be raised but it was not"

# ---------------------------------------------------------------------------
# punycodeEncode — RFC 3492 Section 7.1 test vectors
#
# The ACE prefix ("xn--") is not shown; these are raw Punycode outputs.
# Mixed-case annotation (Appendix A) is not implemented; encoding digits are
# always lowercase. The one RFC case affected is (I) Russian, where the RFC
# shows an uppercase 'D' from the optional annotation; we expect lowercase 'd'.
# ---------------------------------------------------------------------------

proc testPunycode() =
  # manually-verified spot checks
  check punycodeEncode("münchen") == "mnchen-3ya"
  check punycodeEncode("bücher")  == "bcher-kva"
  check punycodeEncode("例")      == "fsq"
  check punycodeEncode("abc")     == "abc-"   # ASCII only: basic + delimiter

  # (A) Arabic (Egyptian)
  check punycodeEncode("ليهمابتكلموشعربي؟") == "egbpdaj6bu4bxfgehfvwxn"

  # (B) Chinese (simplified)
  check punycodeEncode("他们为什么不说中文") == "ihqwcrb4cv8a8dqg056pqjye"

  # (C) Chinese (traditional)
  check punycodeEncode("他們爲什麽不說中文") == "ihqwctvzc91f659drss3x8bo0yb"

  # (D) Czech — ASCII prefix preserves case, encoding digits are lowercase
  check punycodeEncode("Pročprostěnemluvíčesky") == "Proprostnemluvesky-uyb24dma41a"

  # (E) Hebrew
  check punycodeEncode("למההםפשוטלאמדבריםעברית") == "4dbcagdahymbxekheh6e0a7fei0b"

  # (F) Hindi (Devanagari) - "यहलोगहिन्दीक्योंनहींबोलसकतेहैं" (30 RFC codepoints)
  check punycodeEncode(
    "यहलोगहिन" &
    "्दीक्यों" &
    "नहींबोलस" &
    "कतेहैं",
  ) == "i1baa7eci9glrd9b2ae1bj0hfcgg6iyaf8o0a1dig0cd"

  # (G) Japanese (kanji and hiragana)
  check punycodeEncode("なぜみんな日本語を話してくれないのか") == "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"

  # (H) Korean (Hangul syllables)
  check punycodeEncode("세계의모든사람들이한국어를이해한다면얼마나좋을까") ==
    "989aomsvi5e83db1d2a355cv1e0vak1dwrv93d5xbh15a0dt30a5jpsd879ccm6fea98c"

  # (I) Russian - "почемужеониненговорятпорусски" (28 RFC codepoints)
  # RFC shows uppercase 'D' (mixed-case annotation); our impl outputs 'd'.
  check punycodeEncode(
    "почемуже" &
    "онинегов" &
    "орятпору" &
    "сски",
  ) == "b1abfaaepdrnnbgefbadotcwatmq2g4l"

  # (J) Spanish — ASCII prefix preserves case
  check punycodeEncode("PorquénopuedensimplementehablarenEspañol") ==
    "PorqunopuedensimplementehablarenEspaol-fmd56a"

  # (K) Vietnamese — ASCII prefix preserves case
  check punycodeEncode("TạisaohọkhôngthểchỉnóitiếngViệt") ==
    "TisaohkhngthchnitingVit-kjcr8268qyxafd2f1b9g"

  # (L) Japanese: 3年B組金八先生
  check punycodeEncode("3年B組金八先生") == "3B-ww4c5e180e575a65lsy2b"

  # (M) Japanese: 安室奈美恵-with-SUPER-MONKEYS
  check punycodeEncode("安室奈美恵-with-SUPER-MONKEYS") ==
    "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n"

  # (N) Japanese: Hello-Another-Way-それぞれの場所
  check punycodeEncode("Hello-Another-Way-それぞれの場所") ==
    "Hello-Another-Way--fc4qua05auwb3674vfr0b"

  # (O) Japanese: ひとつ屋根の下2
  check punycodeEncode("ひとつ屋根の下2") == "2-u9tlzr9756bt3uc0v"

  # (P) Japanese: MajiでKoiする5秒前
  check punycodeEncode("MajiでKoiする5秒前") == "MajiKoi5-783gue6qz075azm5e"

  # (Q) Japanese: パフィーdeルンバ
  check punycodeEncode("パフィーdeルンバ") == "de-jg4avhby1noc0d"

  # (R) Japanese: そのスピードで
  check punycodeEncode("そのスピードで") == "d9juau41awczczp"

# ---------------------------------------------------------------------------
# toAsciiDomain
# ---------------------------------------------------------------------------

proc testToAsciiDomain() =
  # Pure ASCII passes through unchanged
  check toAsciiDomain("google.com")         == "google.com"
  check toAsciiDomain("foo.example.org")    == "foo.example.org"

  # Unicode labels get xn-- encoding
  check toAsciiDomain("münchen.de")  == "xn--mnchen-3ya.de"
  check toAsciiDomain("bücher.de")   == "xn--bcher-kva.de"

  # Already-encoded xn-- labels are ASCII, pass through unchanged
  check toAsciiDomain("xn--mnchen-3ya.de") == "xn--mnchen-3ya.de"

  # Empty labels (adjacent dots) are rejected
  checkRaises(ValueError):
    discard toAsciiDomain("foo..bar")

  # Label exactly 63 chars is valid
  check toAsciiDomain("a".repeat(63) & ".com") == "a".repeat(63) & ".com"

  # Label of 64 chars raises ValueError
  checkRaises(ValueError):
    discard toAsciiDomain("a".repeat(64) & ".com")

  # Hostname of exactly 253 chars is valid (four 62-char labels with dots = 4*62+3 = 251; add one more)
  # Build a valid 253-char hostname: three 63-char labels plus a 62-char label = 63+1+63+1+63+1+62 = 254 -- too long
  # Use 63+1+63+1+61 = 189 then add more: 63.63.63.61 = 253 chars? 63+1+63+1+63+1+61 = 253 - yes!
  let validLong = "a".repeat(63) & "." & "b".repeat(63) & "." &
                  "c".repeat(63) & "." & "d".repeat(61)
  check validLong.len == 253
  check toAsciiDomain(validLong) == validLong

  # Hostname of 254 chars raises ValueError
  let tooLong = "a".repeat(63) & "." & "b".repeat(63) & "." &
                "c".repeat(63) & "." & "d".repeat(62)
  check tooLong.len == 254
  checkRaises(ValueError):
    discard toAsciiDomain(tooLong)

# ---------------------------------------------------------------------------
# parseServerPort
# ---------------------------------------------------------------------------

proc testParseServerPort() =
  block:
    let (h, p) = parseServerPort("8.8.8.8")
    check h == "8.8.8.8" and int(p) == 53

  block:
    let (h, p) = parseServerPort("8.8.8.8:5353")
    check h == "8.8.8.8" and int(p) == 5353

  block:
    let (h, p) = parseServerPort("[::1]")
    check h == "::1" and int(p) == 53

  block:
    let (h, p) = parseServerPort("[::1]:5353")
    check h == "::1" and int(p) == 5353

  block:
    let (h, p) = parseServerPort("[2001:db8::1]")
    check h == "2001:db8::1" and int(p) == 53

  block:
    let (h, p) = parseServerPort("[2001:db8::1]:5353")
    check h == "2001:db8::1" and int(p) == 5353

  # Bare IPv6 (no brackets) — falls back via parseUri mismatch detection
  block:
    let (h, p) = parseServerPort("::1")
    check h == "::1" and int(p) == 53

  block:
    let (h, p) = parseServerPort("2001:db8::1")
    check h == "2001:db8::1" and int(p) == 53

  # Port boundary values
  block:
    let (h, p) = parseServerPort("8.8.8.8:1")
    check h == "8.8.8.8" and int(p) == 1

  block:
    let (h, p) = parseServerPort("8.8.8.8:65535")
    check h == "8.8.8.8" and int(p) == 65535

  # Out-of-range port falls back to default (host must still be extracted correctly)
  block:
    let (h, p) = parseServerPort("8.8.8.8:0")
    check h == "8.8.8.8" and int(p) == 53

  block:
    let (h, p) = parseServerPort("8.8.8.8:65536")
    check h == "8.8.8.8" and int(p) == 53

  block:
    let (h, p) = parseServerPort("8.8.8.8:99999")
    check h == "8.8.8.8" and int(p) == 53

  # Non-numeric port falls back to default (host still extracted)
  block:
    let (h, p) = parseServerPort("8.8.8.8:abc")
    check h == "8.8.8.8" and int(p) == 53

  # Bracketed IPv6 with out-of-range port
  block:
    let (h, p) = parseServerPort("[::1]:0")
    check h == "::1" and int(p) == 53

  block:
    let (h, p) = parseServerPort("[::1]:65536")
    check h == "::1" and int(p) == 53

  # Bracketed IPv6 with non-numeric port
  block:
    let (h, p) = parseServerPort("[::1]:abc")
    check h == "::1" and int(p) == 53

# ---------------------------------------------------------------------------
# dnsLookup - error paths (no network traffic required)
# ---------------------------------------------------------------------------

proc testDnsLookupValidation() =
  # Invalid label length raises ValueError before any socket is opened
  checkRaises(ValueError):
    dnsLookup("a".repeat(64) & ".com")

  # Invalid total length raises ValueError
  checkRaises(ValueError):
    dnsLookup(
      "a".repeat(63) & "." & "b".repeat(63) & "." &
      "c".repeat(63) & "." & "d".repeat(62),
    )

proc testDnsLookupTimeout() =
  # 192.0.2.x is TEST-NET (RFC 5737), routable but never responds.
  # With a 100ms timeout the query must time out rather than hang.
  var timedOut = false
  try:
    dnsLookup(
      domain    = "example.com",
      server    = "192.0.2.1",
      timeoutMs = 100,
    )
  except IOError as e:
    if "timed out" in e.msg:
      timedOut = true
  check timedOut

var gStubFd   {.global.}: cint = -1
var gStubDone {.global.}: bool = false

proc runStub(ignored: int) {.thread.} =
  # Receive one query datagram, then send two replies:
  # 1) wrong transaction ID (XOR 0xFF on both ID bytes) -- must be discarded
  # 2) correct transaction ID, RCODE=0                  -- must be accepted
  var
    query:   array[512, byte]
    fromSa:  array[128, byte]
    fromLen = SockLen(128)
  let n = posix.recvfrom(
    SocketHandle(gStubFd),
    cast[pointer](addr query[0]),
    512,
    cint(0),
    cast[ptr SockAddr](addr fromSa[0]),
    addr fromLen,
  )
  if n < 2:
    gStubDone = true
    return
  var bad:  array[12, byte]
  var good: array[12, byte]
  bad[0]  = query[0] xor byte(0xFF)
  bad[1]  = query[1] xor byte(0xFF)
  bad[2]  = byte(0x80)
  good[0] = query[0]
  good[1] = query[1]
  good[2] = byte(0x80)
  discard posix.sendto(
    SocketHandle(gStubFd), cast[pointer](addr bad[0]), 12, cint(0),
    cast[ptr SockAddr](addr fromSa[0]), fromLen,
  )
  discard posix.sendto(
    SocketHandle(gStubFd), cast[pointer](addr good[0]), 12, cint(0),
    cast[ptr SockAddr](addr fromSa[0]), fromLen,
  )
  gStubDone = true

proc testDnsTransactionIdValidation() =
  # Bind a stub UDP server on a random loopback port.  The stub sends a
  # bad-ID response first, then a good-ID response.  dnsLookup must discard
  # the first and succeed on the second.
  let srv = newSocket(
    domain   = Domain.AF_INET,
    sockType = SockType.SOCK_DGRAM,
    protocol = Protocol.IPPROTO_UDP,
    buffered = false,
  )
  defer: srv.close()
  srv.bindAddr(Port(0), "127.0.0.1")
  let (_, srvPort) = srv.getLocalAddr()
  gStubFd   = srv.getFd().cint
  gStubDone = false

  var t: Thread[int]
  createThread(t, runStub, 0)
  dnsLookup(
    domain    = "example.com",
    server    = "127.0.0.1:" & $srvPort,
    timeoutMs = 2000,
  )
  joinThread(t)
  check gStubDone

# ---------------------------------------------------------------------------

testPunycode()
testToAsciiDomain()
testParseServerPort()
testDnsLookupValidation()
testDnsLookupTimeout()
testDnsTransactionIdValidation()
echo "All DNS tests passed."
