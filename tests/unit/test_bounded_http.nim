import std/[
  json,
  monotimes,
  net,
  os,
  osproc,
  strutils,
  streams,
  strtabs,
  tempfiles,
  times,
  uri,
]
import ../../src/utils/bounded_http
import ../../src/utils/http

proc linkInsertCommand(path: seq[string])
    {.exportc: "runCmdInsert", cdecl.} =
  discard

proc linkExtractCommand(path: seq[string])
    {.exportc: "runCmdExtract", cdecl.} =
  discard

proc linkDeleteCommand(path: seq[string])
    {.exportc: "runCmdDelete", cdecl.} =
  discard

const fixtureServer = currentSourcePath().parentDir() / "fixtures" / "http_fixture.py"

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc freePort(): int =
  let s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

proc waitReady(port: int) =
  for i in 0 .. 50:
    try:
      let s = newSocket()
      s.connect("127.0.0.1", Port(port))
      s.close()
      return
    except:
      sleep(20)
  doAssert false, "http fixture did not start"

proc startServer(dir: string, routes: JsonNode, port: int, cert = "", key = ""): tuple[p: Process, hits: string] =
  let routeFile = dir / "routes.json"
  let hits = dir / "hits.log"
  writeFile(routeFile, $routes)
  writeFile(hits, "")
  var arguments = @["-I", fixtureServer, routeFile, hits, $port]
  if cert != "":
    arguments.add(@[cert, key, dir / "sni.log"])
  let p = startProcess(
    findExe("python3"),
    args = arguments,
    options = {poUsePath, poStdErrToStdOut},
  )
  waitReady(port)
  return (p, hits)

proc stopServer(p: Process) =
  terminate(p)
  discard waitForExit(p, 1000)
  close(p)

proc budget(timeoutMs: int, maxBodyBytes = 1000): HttpBudget =
  HttpBudget(
    deadline:     getMonoTime() + initDuration(milliseconds = timeoutMs),
    maxBodyBytes: maxBodyBytes,
  )

proc get(port: int, path: string, budget: HttpBudget,
         headers: HttpHeaders = nil, maxRedirects = 3): Response =
  boundedRequest(
    parseUri("http://127.0.0.1:" & $port & path), HttpGet, budget,
    headers = headers, maxRedirects = maxRedirects,
  )

proc main() =
  let dir = createTempDir("chalk-bounded-http-", "")
  let port = freePort()
  let other = "http://localhost:" & $port
  let otherPort = freePort()
  let otherDir = dir / "other"
  createDir(otherDir)
  var routes = %*{
    "GET /plain": {"status": 200, "body": "hello", "headers": {"X-Test": "yes"}},
    "HEAD /head": {"status": 200, "body": "", "headers": {"Content-Length": "99999999"}},
    "GET /lying-length": {"status": 200, "body": "0123456789", "content_length": 5000},
    "GET /chunked-ok": {"status": 200, "body": "c".repeat(500), "chunked": true},
    "GET /chunked-big": {"status": 200, "body": "c".repeat(5000), "chunked": true},
    "GET /slow": {"status": 200, "body": "s".repeat(500),
                  "drip": {"chunk": 10, "delay_ms": 200}},
    "GET /echo": {"status": 200, "echo_authorization": true},
    "GET /same-host": {"status": 302, "body": "", "headers": {"Location": "/echo"}},
    "GET /cross-host": {"status": 307, "body": "",
                        "headers": {"Location": other & "/echo"}},
    "GET /cross-port": {"status": 302, "body": "",
                        "headers": {"Location": "http://127.0.0.1:" & $otherPort & "/echo"}},
    "GET /nested/relative": {"status": 302, "body": "", "headers": {"Location": "../echo"}},
    "GET /query": {"status": 302, "body": "", "headers": {"Location": "?done=1"}},
    "GET /query?done=1": {"status": 200, "echo_authorization": true},
    "GET /loop": {"status": 302, "body": "", "headers": {"Location": "/loop"}},
    "GET /big-redirect": {"status": 302, "body": "r".repeat(5000), "chunked": true,
                          "headers": {"Location": "/plain"}},
  }
  let (p, hits) = startServer(dir, routes, port)
  let (otherServer, _) = startServer(otherDir, %*{"GET /echo": {"status": 200, "echo_authorization": true}}, otherPort)
  try:
    block plain:
      let response = get(port, "/plain", budget(2000))
      assertEq(int(response.code()), 200)
      assertEq(response.body(), "hello")
      assertEq(response.headers["X-Test"], "yes")

    block headIgnoresDeclaredLength:
      let response = boundedRequest(
        parseUri("http://127.0.0.1:" & $port & "/head"), HttpHead, budget(2000))
      assertEq(int(response.code()), 200)
      assertEq(response.headers["Content-Length"], "99999999")
      assertEq(response.body(), "")

    block declaredTooLarge:
      doAssertRaises(HttpBodyTooLargeError):
        discard get(port, "/lying-length", budget(2000))

    block chunkedWithinLimit:
      assertEq(get(port, "/chunked-ok", budget(2000)).body(), "c".repeat(500))

    block chunkedTooLarge:
      doAssertRaises(HttpBodyTooLargeError):
        discard get(port, "/chunked-big", budget(2000))

    block slowBodyHitsDeadline:
      let start = getMonoTime()
      doAssertRaises(HttpDeadlineError):
        discard get(port, "/slow", budget(300))
      let elapsed = (getMonoTime() - start).inMilliseconds
      doAssert elapsed < 1500, "slow body outlived the budget: " & $elapsed & "ms"

    block expiredBudgetSendsNothing:
      writeFile(hits, "")
      doAssertRaises(HttpDeadlineError):
        discard get(port, "/plain", budget(-1))
      assertEq(readFile(hits), "")

    block sameHostRedirectKeepsAuthorization:
      let headers = newHttpHeaders({"Authorization": "Basic abc"})
      assertEq(get(port, "/same-host", budget(2000), headers).body(), "Basic abc")

    block crossHostRedirectDropsAuthorization:
      let headers = newHttpHeaders({"Authorization": "Basic abc"})
      assertEq(get(port, "/cross-host", budget(2000), headers).body(), "")
      assertEq(headers["Authorization"], "Basic abc")

    block relativeRedirectsAndCredentialOrigin:
      var failures: seq[string] = @[]
      for (path, expected) in [("/cross-port", ""), ("/nested/relative", "Basic abc"), ("/query", "Basic abc")]:
        try:
          let actual = get(port, path, budget(2000), newHttpHeaders({"Authorization": "Basic abc"})).body()
          if actual != expected:
            failures.add(path & " returned " & actual)
        except CatchableError:
          failures.add(path & " raised " & getCurrentExceptionMsg())
      doAssert failures.len == 0, $failures

    block redirectLimitReturnsLastResponse:
      writeFile(hits, "")
      let response = get(port, "/loop", budget(2000), maxRedirects = 2)
      assertEq(int(response.code()), 302)
      assertEq(readFile(hits).strip().splitLines().len, 3)

    block redirectBodyIsBounded:
      doAssertRaises(HttpBodyTooLargeError):
        discard get(port, "/big-redirect", budget(2000))

    block tlsIdentityAndDeadline:
      let tlsDir = dir / "tls"
      createDir(tlsDir)
      let cert = tlsDir / "certificate.pem"
      let key = tlsDir / "key.pem"
      let certificateCommand = @[findExe("openssl"), "req", "-x509", "-newkey", "rsa:2048",
        "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"]
      doAssert certificateCommand[0] != "", "TLS fixture requires openssl"
      let generated = execCmdEx(quoteShellCommand(certificateCommand))
      doAssert generated.exitCode == 0, generated.output
      let tlsPort = freePort()
      let (tlsServer, _) = startServer(tlsDir, %*{
        "GET /plain": {"status": 200, "body": "tls"},
        "GET /host": {"status": 200, "echo_host": true},
        "GET /slow": {"status": 200, "body": "s".repeat(500),
                      "drip": {"chunk": 10, "delay_ms": 200}},
      }, tlsPort, cert, key)
      try:
        let root = "https://localhost:" & $tlsPort
        assertEq(boundedRequest(parseUri(root & "/plain"), HttpGet, budget(2000), pinnedCert = cert).body(), "tls")
        assertEq(boundedRequest(parseUri(root & "/host"), HttpGet, budget(2000), pinnedCert = cert).body(), "localhost:" & $tlsPort)
        assertEq(boundedRequest(parseUri("https://127.0.0.1:" & $tlsPort & "/plain"), HttpGet,
                                budget(2000), pinnedCert = cert).body(), "tls")
        doAssert "localhost" in readFile(tlsDir / "sni.log")
        doAssertRaises(CatchableError):
          discard boundedRequest(parseUri(root & "/plain"), HttpGet, budget(2000))
        doAssertRaises(HttpDeadlineError):
          discard boundedRequest(parseUri(root & "/slow"), HttpGet, budget(300), pinnedCert = cert)
      finally:
        stopServer(tlsServer)
      let wrongCertificateCommand = @[findExe("openssl"), "req", "-x509", "-newkey", "rsa:2048",
        "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=other.test",
        "-addext", "subjectAltName=DNS:other.test"]
      let wrongGenerated = execCmdEx(quoteShellCommand(wrongCertificateCommand))
      doAssert wrongGenerated.exitCode == 0, wrongGenerated.output
      let wrongPort = freePort()
      let (wrongServer, _) = startServer(tlsDir, %*{"GET /plain": {"status": 200, "body": "wrong"}}, wrongPort, cert, key)
      try:
        doAssertRaises(CatchableError):
          discard boundedRequest(parseUri("https://localhost:" & $wrongPort & "/plain"), HttpGet,
                                 budget(2000), pinnedCert = cert)
        doAssertRaises(CatchableError):
          discard boundedRequest(parseUri("https://127.0.0.1:" & $wrongPort & "/plain"), HttpGet,
                                 budget(2000), pinnedCert = cert)
      finally:
        stopServer(wrongServer)

    block slowDnsUsesBudget:
      let library = dir / "slow_dns.so"
      let source = fixtureServer.parentDir() / "slow_dns.c"
      let compiler = findExe("cc")
      doAssert compiler != "", "DNS fixture requires a C compiler"
      let arguments =
        when defined(macosx): @[compiler, "-dynamiclib", source, "-o", library]
        else: @[compiler, "-shared", "-fPIC", source, "-o", library, "-ldl", "-pthread"]
      let compiled = execCmdEx(quoteShellCommand(arguments))
      doAssert compiled.exitCode == 0, compiled.output
      var environment = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        environment[key] = value
      when defined(macosx):
        environment["DYLD_INSERT_LIBRARIES"] = library
      else:
        environment["LD_PRELOAD"] = library
      let probe = startProcess(getAppFilename(), args = @["--slow-dns-probe"],
                               env = environment, options = {poStdErrToStdOut})
      let output = probe.outputStream.readAll()
      let exitCode = waitForExit(probe)
      close(probe)
      doAssert exitCode == 0, output

    block completedAndTimedOutResolversReleaseDescriptors:
      let compiler = findExe("cc")
      let repository = currentSourcePath().parentDir().parentDir().parentDir()
      let objectFile = dir / "resolver.o"
      let program = dir / "resolver-check"
      let compiled = execCmdEx(quoteShellCommand(@[compiler, "-pthread", "-Dgetaddrinfo=mock_getaddrinfo",
        "-c", repository / "src/utils/resolve_deadline.c", "-o", objectFile]))
      doAssert compiled.exitCode == 0, compiled.output
      let linked = execCmdEx(quoteShellCommand(@[compiler, "-pthread", objectFile,
        fixtureServer.parentDir() / "resolver_stress.c", "-o", program]))
      doAssert linked.exitCode == 0, linked.output
      let checked = execCmdEx(quoteShellCommand(@[program]))
      doAssert checked.exitCode == 0, checked.output

    block connectionRefused:
      let closed = freePort()
      doAssertRaises(OSError):
        discard get(closed, "/plain", budget(2000))
  finally:
    stopServer(p)
    stopServer(otherServer)
    removeDir(dir)

if paramCount() == 1 and paramStr(1) == "--slow-dns-probe":
  let start = getMonoTime()
  doAssertRaises(HttpDeadlineError):
    discard boundedRequest(parseUri("http://slow-resolver.test/"), HttpGet, budget(200))
  doAssert (getMonoTime() - start).inMilliseconds < 1000,
           "DNS resolution ignored the collection budget"
else:
  main()
