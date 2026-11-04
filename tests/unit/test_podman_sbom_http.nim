import std/[
  json,
  monotimes,
  net,
  options,
  os,
  osproc,
  strutils,
  tempfiles,
  times,
]
import nimutils/sha
import ../../src/docker/[ids, registry]
import ../../src/podman/sbom
import ../../src/podman/types
import ../../src/utils/json
import ../../src/utils/bounded_http

proc linkInsertCommand(path: seq[string])
    {.exportc: "runCmdInsert", cdecl.} =
  discard

proc linkExtractCommand(path: seq[string])
    {.exportc: "runCmdExtract", cdecl.} =
  discard

proc linkDeleteCommand(path: seq[string])
    {.exportc: "runCmdDelete", cdecl.} =
  discard

const sourceDir = currentSourcePath().parentDir().parentDir().parentDir() / "src"
{.passc: "-I" & sourceDir.}

const fixtureServer = currentSourcePath().parentDir() / "fixtures" / "http_fixture.py"

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc expectDocument(outcome: PodmanSbomOutcome): PodmanSbomDocument =
  doAssert outcome.kind == psoDocument, $outcome
  return outcome.document

proc expectDiagnostic(outcome: PodmanSbomOutcome,
                      kind: PodmanSbomDiagnosticKind): PodmanSbomDiagnostic =
  doAssert outcome.kind == psoDiagnostic, $outcome
  assertEq(outcome.diagnostic.kind, kind)
  return outcome.diagnostic

proc sha(bytes: string): string =
  "sha256:" & bytes.sha256Hex()

proc spdxDoc(pad = 0): string =
  """{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT",""" &
  """"name":"img","documentNamespace":"https://example.com/spdx/img",""" &
  """"creationInfo":{"created":"2024-01-01T00:00:00Z","creators":["Tool: test"]},""" &
  """"packages":[]""" & " ".repeat(pad) & "}"

proc freePort(address = "127.0.0.1"): int =
  let s = newSocket(domain = (if address == "::1": AF_INET6 else: AF_INET))
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), address)
  result = int(s.getLocalAddr()[1])
  s.close()

proc waitReady(port: int, address = "127.0.0.1") =
  for i in 0 .. 50:
    try:
      let s = newSocket(domain = (if address == "::1": AF_INET6 else: AF_INET))
      s.connect(address, Port(port))
      s.close()
      return
    except:
      sleep(20)
  doAssert false, "registry mock did not start"

proc startRegistry(dir: string, routes: JsonNode, port: int, mode = ""): tuple[p: Process, hits: string] =
  let routeFile = dir / "routes.json"
  let hits = dir / "hits.log"
  writeFile(routeFile, $routes)
  writeFile(hits, "")
  var arguments = @["-I", fixtureServer, routeFile, hits, $port]
  if mode != "": arguments.add(mode)
  let p = startProcess(
    findExe("python3"),
    args = arguments,
    options = {poUsePath, poStdErrToStdOut},
  )
  waitReady(port, routes{"__bind__"}.getStr("127.0.0.1"))
  return (p, hits)

proc stopRegistry(p: Process) =
  terminate(p)
  discard waitForExit(p, 1000)
  close(p)

proc ociManifest(configDigest, mediaType: string, layers: JsonNode,
                 subject = "", artifactType = ""): string =
  var node = %*{
    "schemaVersion": 2,
    "mediaType": mediaType,
    "config": {
      "mediaType": "application/vnd.oci.image.config.v1+json",
      "digest": configDigest,
      "size": 2,
    },
    "layers": layers,
  }
  if artifactType != "":
    node["artifactType"] = %artifactType
  if subject != "":
    node["subject"] = %*{
      "mediaType": mediaType,
      "digest": subject,
      "size": 2,
    }
  return $node

proc indexDoc(manifests: JsonNode): string =
  $(%*{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": manifests,
  })

proc descriptor(digest: string, size: int): JsonNode =
  %*{
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "digest": digest,
    "size": size,
    "artifactType": "application/spdx+json",
  }

proc route(status: int, body: string, headers: JsonNode = newJObject(),
           delayMs = 0): JsonNode =
  result = %*{
    "status": status,
    "body": body,
    "delay_ms": delayMs,
    "headers": headers,
  }

proc dripping(r: JsonNode, chunk, delayMs: int): JsonNode =
  result = r
  result["drip"] = %*{"chunk": chunk, "delay_ms": delayMs}

proc collectFrom(port: int, imageDigest, configDigest, authFile, attachment: string,
                 timeoutMs = 5000): PodmanSbomOutcome =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  return collectAttachmentPodmanSbom(
    configDigest,
    "127.0.0.1:" & $port & "/demo@" & imageDigest,
    authFile,
    attachment,
    deadline,
  )

proc timedCollect(port: int, imageDigest, configDigest, authFile: string,
                  timeoutMs: int): (PodmanSbomOutcome, int) =
  let start = getMonoTime()
  let outcome = collectFrom(port, imageDigest, configDigest, authFile, "", timeoutMs)
  return (outcome, int((getMonoTime() - start).inMilliseconds))

proc main() =
  let dir = createTempDir("chalk-sbom-http-", "")
  let dockerLog = dir / "docker.log"
  let dockerBin = dir / "bin"
  createDir(dockerBin)
  writeFile(dockerBin / "docker", "#!/bin/sh\necho docker >> \"" & dockerLog & "\"\nexit 1\n")
  setFilePermissions(dockerBin / "docker", {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(dockerLog, "")
  putEnv("PATH", dockerBin & ":" & getEnv("PATH"))
  let authFile = dir / "auth.json"
  writeFile(authFile, $(%*{"auths": {}}))
  let blob = spdxDoc()
  let blobDigest = sha(blob)
  let configDigest = "sha256:" & "c".repeat(64)
  let imageBody = ociManifest(
    configDigest, "application/vnd.oci.image.manifest.v1+json", %*[])
  let imageDigest = sha(imageBody)
  let manifestHeaders = %*{
    "Docker-Content-Digest": imageDigest,
    "Content-Type": "application/vnd.oci.image.manifest.v1+json",
  }
  let attachmentBody = ociManifest(
    configDigest,
    "application/vnd.oci.image.manifest.v1+json",
    %*[{
      "mediaType": "application/spdx+json",
      "digest": blobDigest,
      "size": len(blob),
    }],
    subject = imageDigest,
    artifactType = "application/spdx+json",
  )
  let attachmentDigest = sha(attachmentBody)
  let indexBody = indexDoc(%*[descriptor(attachmentDigest, len(attachmentBody))])

  proc baseRoutes(extra: JsonNode = newJObject()): JsonNode =
    result = extra
    result["GET /v2/demo/manifests/" & imageDigest] = route(200, imageBody, manifestHeaders)
    result["HEAD /v2/demo/manifests/" & imageDigest] = route(
      200, imageBody,
      %*{"Docker-Content-Digest": imageDigest,
         "Content-Type": "application/vnd.oci.image.manifest.v1+json",
         "Content-Length": $len(imageBody)})
    result["GET /v2/demo/blobs/" & blobDigest] = route(
      200, blob, %*{"Content-Type": "application/spdx+json"})

  proc attachmentRoutes(): JsonNode =
    result = baseRoutes()
    result["GET /v2/demo/referrers/" & imageDigest] = route(200, indexBody)
    result["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)

  proc singleLayerAttachment(layerDigest: string, layerSize: int): (string, string) =
    let body = ociManifest(
      configDigest,
      "application/vnd.oci.image.manifest.v1+json",
      %*[{"mediaType": "application/spdx+json", "digest": layerDigest, "size": layerSize}],
      subject = imageDigest,
      artifactType = "application/spdx+json",
    )
    return (body, sha(body))

  try:
    block happy:
      let port = freePort()
      let (p, hits) = startRegistry(dir, attachmentRoutes(), port)
      try:
        let outcome = collectFrom(port, imageDigest, configDigest, authFile, "")
        assertEq(expectDocument(outcome).sourceBytes, blob)
        doAssert "docker" notin readFile(dockerLog)
        let hitText = readFile(hits)
        doAssert "GET /v2/demo/referrers/" & imageDigest in hitText
        doAssert "GET /v2/demo/blobs/" & blobDigest in hitText
      finally:
        stopRegistry(p)

    block defaultAuthFileAccessDoesNotTrustRedirectedChallenges:
      let firstPort = freePort()
      let secondPort = freePort()
      let registry = "127.0.0.1:" & $firstPort
      let credentials = dir / "redirected-default-auth.json"
      let captured = dir / "redirected-default-token-auth"
      let firstCapture = dir / "redirected-default-first-auth"
      writeFile(credentials, $(%*{"auths": {registry: {"auth": "dXNlcjpwYXNz"}}}))
      let secondDir = dir / "redirected-default-second"
      createDir(secondDir)
      let secondRoot = "http://127.0.0.1:" & $secondPort
      var firstRoutes = newJObject()
      firstRoutes["GET /v2/demo/manifests/check"] = %*{
        "status": 200, "body": "{}", "save_authorization": firstCapture}
      firstRoutes["GET /v2/demo/manifests/" & imageDigest] = route(302, "", %*{"Location": secondRoot & "/challenge"})
      let (first, _) = startRegistry(dir, firstRoutes, firstPort)
      let (second, _) = startRegistry(secondDir, %*{
        "GET /challenge": {"status": 401, "body": "denied", "headers": {
          "Www-Authenticate": "Bearer realm=\"" & secondRoot & "/token\""}},
        "GET /token": {"status": 200, "body": "{\"token\":\"public\"}", "save_authorization": captured},
      }, secondPort)
      try:
        withRegistryAccess(newAuthFileRegistryAccess(credentials)):
          discard manifestGet(parseImage(registry & "/demo:check"), "application/json")
          assertEq(readFile(firstCapture), "Basic dXNlcjpwYXNz")
          try:
            discard manifestGet(parseImage(registry & "/demo@" & imageDigest), "application/json")
          except RegistryResponseError:
            discard
        doAssert not fileExists(captured) or readFile(captured) == "",
                 "default auth-file access sent registry credentials to a redirected challenge realm"
      finally:
        stopRegistry(first)
        stopRegistry(second)

    block abortedTlsCannotSendCredentialsOverHttp:
      let port = freePort()
      let captured = dir / "aborted-tls-authorization"
      let credentialFile = dir / "aborted-tls-auth.json"
      let registry = "127.0.0.1:" & $port
      writeFile(credentialFile, $(%*{"auths": {registry: {"auth": "dXNlcjpwYXNz"}}}))
      var routes = newJObject()
      routes["GET /v2/demo/manifests/" & imageDigest] = %*{
        "status": 200, "body": "{}", "save_authorization": captured}
      let (p, hits) = startRegistry(dir, routes, port, "abort-tls")
      try:
        for bounded in [true, false]:
          let access = newAuthFileRegistryAccess(credentialFile)
          if bounded:
            access.budget = some(HttpBudget(deadline: getMonoTime() + initDuration(seconds = 3),
                                           maxBodyBytes: maxPodmanSbomBytes))
          var failed = false
          withRegistryAccess(access):
            try:
              discard manifestGet(parseImage(registry & "/demo@" & imageDigest), "application/json")
            except RegistryResponseError:
              failed = true
          doAssert failed, "aborted TLS handshake advanced to a plaintext registry request"
          doAssert not fileExists(captured), "plaintext retry exposed the auth-file credential"
          assertEq(readFile(hits), "")
      finally:
        stopRegistry(p)

    block ipv6LoopbackHttpRegistry:
      let port = freePort("::1")
      var routes = newJObject()
      routes["__bind__"] = %"::1"
      routes["GET /v2/demo/manifests/" & imageDigest] = %*{"status": 200, "echo_host_json": true}
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let access = newAuthFileRegistryAccess(authFile)
        access.budget = some(HttpBudget(deadline: getMonoTime() + initDuration(seconds = 3),
                                       maxBodyBytes: maxPodmanSbomBytes))
        withRegistryAccess(access):
          let document = manifestGet(parseImage("[::1]:" & $port & "/demo@" & imageDigest), "application/json")
          assertEq(document.json["host"].getStr(), "[::1]:" & $port)
      finally:
        stopRegistry(p)

    block absent:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(404, "")
      routes["GET /v2/demo/manifests/sha256-" & imageDigest[7 .. ^1]] = route(404, "")
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentAbsent)
      finally:
        stopRegistry(p)

    block tagFallback:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(404, "")
      routes["GET /v2/demo/manifests/sha256-" & imageDigest[7 .. ^1]] = route(200, indexBody)
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "sha256-" & imageDigest[7 .. ^1] in readFile(hits)
      finally:
        stopRegistry(p)

    block wrongGetDigest:
      var routes = baseRoutes()
      let corrupt = imageBody & " "
      routes["GET /v2/demo/manifests/" & imageDigest] = route(200, corrupt, manifestHeaders)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentMismatch)
      finally:
        stopRegistry(p)

    block wrongSubject:
      let otherSubject = "sha256:" & "d".repeat(64)
      let badAttach = ociManifest(
        configDigest,
        "application/vnd.oci.image.manifest.v1+json",
        %*[{
          "mediaType": "application/spdx+json",
          "digest": blobDigest,
          "size": len(blob),
        }],
        subject = otherSubject,
        artifactType = "application/spdx+json",
      )
      let badDigest = sha(badAttach)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[descriptor(badDigest, len(badAttach))]))
      routes["GET /v2/demo/manifests/" & badDigest] = route(200, badAttach)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentAbsent)
      finally:
        stopRegistry(p)

    block wrongMedia:
      let badAttach = ociManifest(
        configDigest,
        "application/vnd.oci.image.manifest.v1+json",
        %*[{
          "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
          "digest": blobDigest,
          "size": len(blob),
        }],
        subject = imageDigest,
        artifactType = "application/vnd.oci.image.manifest.v1+json",
      )
      let badDigest = sha(badAttach)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": badDigest,
        "size": len(badAttach),
      }]))
      routes["GET /v2/demo/manifests/" & badDigest] = route(200, badAttach)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentAbsent)
      finally:
        stopRegistry(p)

    block multipleLayers:
      let multi = ociManifest(
        configDigest,
        "application/vnd.oci.image.manifest.v1+json",
        %*[
          {"mediaType": "application/spdx+json", "digest": blobDigest, "size": len(blob)},
          {"mediaType": "application/spdx+json", "digest": blobDigest, "size": len(blob)},
        ],
        subject = imageDigest,
        artifactType = "application/spdx+json",
      )
      let multiDigest = sha(multi)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[descriptor(multiDigest, len(multi))]))
      routes["GET /v2/demo/manifests/" & multiDigest] = route(200, multi)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, multiDigest),
          pdkAttachmentMismatch)
      finally:
        stopRegistry(p)

    block ambiguousAndSelect:
      let secondBlob = spdxDoc().replace("img", "img2")
      let secondBlobDigest = sha(secondBlob)
      let (secondAttach, secondDigest) = singleLayerAttachment(secondBlobDigest, len(secondBlob))
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[
        descriptor(attachmentDigest, len(attachmentBody)),
        descriptor(secondDigest, len(secondAttach)),
      ]))
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      routes["GET /v2/demo/manifests/" & secondDigest] = route(200, secondAttach)
      routes["GET /v2/demo/blobs/" & secondBlobDigest] = route(
        200, secondBlob, %*{"Content-Type": "application/spdx+json"})
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentAmbiguous)
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, secondDigest)
        ).sourceBytes, secondBlob)
      finally:
        stopRegistry(p)

    block corruptBlob:
      var routes = attachmentRoutes()
      routes["GET /v2/demo/blobs/" & blobDigest] = route(200, blob & "nope")
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentMismatch)
      finally:
        stopRegistry(p)

    block originChange:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[]),
        %*{"Link": "<https://evil.example/v2/demo/referrers/next>; rel=\"next\""})
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        let diag = expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentMismatch)
        doAssert "origin" in diag.message
        doAssert "evil.example" notin readFile(hits)
        doAssert "credentials" notin diag.message
      finally:
        stopRegistry(p)

    block queryPage:
      let page2 = indexDoc(%*[descriptor(attachmentDigest, len(attachmentBody))])
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[]),
        %*{"Link": "<?n=2>; rel=\"next\""})
      routes["GET /v2/demo/referrers/" & imageDigest & "?n=2"] = route(200, page2)
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "?n=2" in readFile(hits)
      finally:
        stopRegistry(p)

    block pageLoop:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[]),
        %*{"Link": "<?n=2>; rel=\"next\""})
      var loopHeaders = newJObject()
      loopHeaders["Link"] = % ("</v2/demo/referrers/" & imageDigest & ">; rel=\"next\"")
      routes["GET /v2/demo/referrers/" & imageDigest & "?n=2"] = route(
        200, indexDoc(%*[]), loopHeaders)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let diag = expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAttachmentMismatch)
        doAssert "repeated" in diag.message
      finally:
        stopRegistry(p)

    block authFailure:
      var routes = newJObject()
      routes["GET /v2/demo/manifests/" & imageDigest] = route(
        401, "denied",
        %*{"Www-Authenticate": "Bearer realm=\"http://127.0.0.1/token\""})
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let diag = expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAuthFailure)
        doAssert diag.message == "registry authentication failed"
        doAssert "denied" notin diag.message
      finally:
        stopRegistry(p)

    block forbidden:
      var routes = newJObject()
      routes["GET /v2/demo/manifests/" & imageDigest] = route(403, "forbidden")
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let diag = expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAuthFailure)
        doAssert "forbidden" notin diag.message
      finally:
        stopRegistry(p)

    block redirectedIndexUsesItsEffectivePath:
      var routes = attachmentRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(302, "", %*{"Location": "/pages/first"})
      routes["GET /pages/first"] = route(200, indexDoc(%*[]), %*{"Link": "<next>; rel=\"next\""})
      routes["GET /pages/next"] = route(200, indexDoc(%*[descriptor(attachmentDigest, len(attachmentBody))]))
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        assertEq(expectDocument(collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "GET /pages/next" in readFile(hits)
      finally:
        stopRegistry(p)

    block cachedRedirectedIndexRetainsItsEffectivePath:
      var routes = attachmentRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(302, "", %*{"Location": "/pages/first"})
      routes["GET /pages/first"] = route(200, indexDoc(%*[]), %*{"Link": "<next>; rel=\"next\""})
      routes["GET /pages/next"] = route(200, indexDoc(%*[descriptor(attachmentDigest, len(attachmentBody))]))
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        let access = newAuthFileRegistryAccess(authFile)
        access.strictReferrerLinks = true
        access.budget = some(HttpBudget(deadline: getMonoTime() + initDuration(seconds = 5),
                                       maxBodyBytes: maxPodmanSbomBytes))
        withRegistryAccess(access):
          let image = parseImage("127.0.0.1:" & $port & "/demo@" & imageDigest)
          let original = image.referrersGet()
          discard manifestGet(image.withDigest(attachmentDigest), "application/vnd.oci.image.manifest.v1+json")
          let before = readFile(hits)
          let cached = image.referrersGet()
          assertEq(cached.json, original.json)
          assertEq(readFile(hits), before)
      finally:
        stopRegistry(p)

    block unexpectedStatusDoesNotProveAbsence:
      for status in [408, 429]:
        var routes = newJObject()
        routes["GET /v2/demo/manifests/" & imageDigest] = route(status, "retry later")
        let port = freePort()
        let (p, _) = startRegistry(dir, routes, port)
        try:
          discard expectDiagnostic(collectFrom(port, imageDigest, configDigest, authFile, ""), pdkOther)
        finally:
          stopRegistry(p)

    block serverErrorIsNotAttachmentAbsence:
      var routes = newJObject()
      routes["GET /v2/demo/manifests/" & imageDigest] = route(503, "unavailable")
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(collectFrom(port, imageDigest, configDigest, authFile, ""), pdkOther)
      finally:
        stopRegistry(p)

    block unavailableCandidateRequiresExplicitSelection:
      let unavailable = "sha256:" & "f".repeat(64)
      var routes = attachmentRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[
        descriptor(unavailable, 100), descriptor(attachmentDigest, len(attachmentBody)),
      ]))
      routes["GET /v2/demo/manifests/" & unavailable] = route(503, "unavailable")
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(collectFrom(port, imageDigest, configDigest, authFile, ""), pdkOther)
        assertEq(expectDocument(collectFrom(port, imageDigest, configDigest, authFile, attachmentDigest)).sourceBytes, blob)
      finally:
        stopRegistry(p)

    block nonStrictReferrersPreserveOriginalDocument:
      let raw = " { \"schemaVersion\": 2, \"annotations\": {\"kept\": \"value\"}, \"manifests\": [] } "
      var routes = newJObject()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, raw)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        withRegistryAccess(newAuthFileRegistryAccess(authFile)):
          let image = parseImage("127.0.0.1:" & $port & "/demo@" & imageDigest)
          let document = image.referrersGet()
          doAssert document != nil
          assertEq(document.digest, sha(raw))
          assertEq(document.json{"annotations"}{"kept"}.getStr(), "value")
      finally:
        stopRegistry(p)

    block notFoundWithAuthLikeDigest:
      let digest401 = "sha256:401" & "a".repeat(61)
      let port = freePort()
      let (p, hits) = startRegistry(dir, newJObject(), port)
      try:
        discard expectDiagnostic(
          collectFrom(port, digest401, configDigest, authFile, ""),
          pdkAttachmentAbsent)
        doAssert "GET /v2/demo/manifests/" & digest401 in readFile(hits)
      finally:
        stopRegistry(p)

    block missingCandidateWithAuthLikeDigest:
      let digest403 = "sha256:403" & "b".repeat(61)
      var routes = attachmentRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[
        descriptor(digest403, 100),
        descriptor(attachmentDigest, len(attachmentBody)),
      ]))
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "GET /v2/demo/manifests/" & digest403 in readFile(hits)
      finally:
        stopRegistry(p)

    block bearerChallenge:
      let port = freePort()
      var routes = attachmentRoutes()
      let realm = "http://127.0.0.1:" & $port & "/token"
      for key in ["GET /v2/demo/manifests/" & imageDigest,
                  "GET /v2/demo/referrers/" & imageDigest,
                  "GET /v2/demo/manifests/" & attachmentDigest,
                  "GET /v2/demo/blobs/" & blobDigest]:
        routes[key]["auth"] = %*{
          "header": "Bearer tok",
          "challenge": "Bearer realm=\"" & realm & "\",service=\"demo\"",
        }
      routes["GET /token"] = route(200, $(%*{"token": "tok"}))
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "GET /token?service=demo" in readFile(hits)
      finally:
        stopRegistry(p)

    block oversizedTokenBody:
      let port = freePort()
      var routes = attachmentRoutes()
      let realm = "http://127.0.0.1:" & $port & "/token"
      routes["GET /v2/demo/manifests/" & imageDigest]["auth"] = %*{
        "header": "Bearer tok", "challenge": "Bearer realm=\"" & realm & "\"",
      }
      routes["GET /token"] = route(200, "{}")
      routes["GET /token"]["content_length"] = %(maxPodmanSbomBytes + 1)
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(collectFrom(port, imageDigest, configDigest, authFile, ""), pdkOversized)
      finally:
        stopRegistry(p)

    block slowTokenChallenge:
      let port = freePort()
      var routes = attachmentRoutes()
      let realm = "http://127.0.0.1:" & $port & "/token"
      routes["GET /v2/demo/manifests/" & imageDigest]["auth"] = %*{
        "header": "Bearer tok",
        "challenge": "Bearer realm=\"" & realm & "\"",
      }
      routes["GET /token"] = route(200, $(%*{"token": "tok"}), delayMs = 3000)
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let (outcome, elapsed) = timedCollect(port, imageDigest, configDigest, authFile, 500)
        discard expectDiagnostic(outcome, pdkTimeout)
        doAssert elapsed < 2000, "token challenge ignored the deadline: " & $elapsed & "ms"
      finally:
        stopRegistry(p)

    block timeout:
      var routes = baseRoutes()
      routes["GET /v2/demo/manifests/" & imageDigest] = route(200, imageBody, manifestHeaders, delayMs = 1000)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, "", timeoutMs = 200),
          pdkTimeout)
      finally:
        stopRegistry(p)

    block slowManifestBody:
      var routes = attachmentRoutes()
      routes["GET /v2/demo/manifests/" & imageDigest] =
        route(200, imageBody, manifestHeaders).dripping(chunk = 20, delayMs = 250)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let (outcome, elapsed) = timedCollect(port, imageDigest, configDigest, authFile, 500)
        discard expectDiagnostic(outcome, pdkTimeout)
        doAssert elapsed < 2000, "manifest body read outlived the budget: " & $elapsed & "ms"
      finally:
        stopRegistry(p)

    block slowBlobBody:
      let bigBlob = spdxDoc(pad = 60000)
      let bigBlobDigest = sha(bigBlob)
      let (bigAttach, bigDigest) = singleLayerAttachment(bigBlobDigest, len(bigBlob))
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[descriptor(bigDigest, len(bigAttach))]))
      routes["GET /v2/demo/manifests/" & bigDigest] = route(200, bigAttach)
      routes["GET /v2/demo/blobs/" & bigBlobDigest] =
        route(200, bigBlob, %*{"Content-Type": "application/spdx+json"})
        .dripping(chunk = 4096, delayMs = 200)
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        let (outcome, elapsed) = timedCollect(port, imageDigest, configDigest, authFile, 500)
        discard expectDiagnostic(outcome, pdkTimeout)
        doAssert elapsed < 2000, "blob read outlived the budget: " & $elapsed & "ms"
      finally:
        stopRegistry(p)

    block oversizedDeclared:
      let hugeDigest = "sha256:" & "e".repeat(64)
      let hugeSize = 40 * 1024 * 1024
      let (hugeAttach, hugeAttachDigest) = singleLayerAttachment(hugeDigest, hugeSize)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[descriptor(hugeAttachDigest, len(hugeAttach))]))
      routes["GET /v2/demo/manifests/" & hugeAttachDigest] = route(200, hugeAttach)
      routes["GET /v2/demo/blobs/" & hugeDigest] = %*{
        "status": 200,
        "body_repeat": {"byte": "x", "count": hugeSize},
        "headers": {"Content-Type": "application/spdx+json"},
      }
      let port = freePort()
      let (p, hits) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkOversized)
        doAssert "GET /v2/demo/blobs/" & hugeDigest notin readFile(hits),
          "blob was fetched despite its declared size"
      finally:
        stopRegistry(p)

    block oversizedStream:
      let lyingDigest = "sha256:" & "f".repeat(64)
      let (lyingAttach, lyingAttachDigest) = singleLayerAttachment(lyingDigest, 100)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[descriptor(lyingAttachDigest, len(lyingAttach))]))
      routes["GET /v2/demo/manifests/" & lyingAttachDigest] = route(200, lyingAttach)
      routes["GET /v2/demo/blobs/" & lyingDigest] = %*{
        "status": 200,
        "body_repeat": {"byte": "x", "count": maxPodmanSbomBytes + 65536},
        "chunked": true,
        "headers": {"Content-Type": "application/spdx+json"},
      }
      let port = freePort()
      let (p, _) = startRegistry(dir, routes, port)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkOversized)
      finally:
        stopRegistry(p)

    doAssert "docker" notin readFile(dockerLog)
  finally:
    removeDir(dir)

main()
