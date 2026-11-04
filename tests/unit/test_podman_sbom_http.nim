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
import ../../src/podman/sbom
import ../../src/podman/types
import ../../src/utils/json

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

proc spdxDoc(): string =
  """{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT",""" &
  """"name":"img","documentNamespace":"https://example.com/spdx/img",""" &
  """"creationInfo":{"created":"2024-01-01T00:00:00Z","creators":["Tool: test"]},""" &
  """"packages":[]}"""

const registryPy = """
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, sys, time

routes = json.loads(open(sys.argv[1]).read())
hits_path = sys.argv[2]
port = int(sys.argv[3])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def respond(self, method):
        key = method + " " + self.path
        with open(hits_path, "a") as hits:
            hits.write(key + "\\n")
        route = routes.get(key) or routes.get(method + " " + self.path.split("?", 1)[0])
        if route is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        delay = route.get("delay_ms", 0)
        if delay:
            time.sleep(delay / 1000.0)
        body = route.get("body", "").encode()
        self.send_response(int(route.get("status", 200)))
        headers = route.get("headers", {})
        for name, value in headers.items():
            self.send_header(name, value)
        if "Content-Type" not in headers:
            self.send_header("Content-Type", route.get("content_type", "application/json"))
        if method != "HEAD":
            self.send_header("Content-Length", str(len(body)))
        elif "Content-Length" not in headers:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        self.respond("GET")

    def do_HEAD(self):
        self.respond("HEAD")

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
"""

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
  doAssert false, "registry mock did not start"

proc startRegistry(dir: string, routes: JsonNode): tuple[p: Process, port: int, hits: string] =
  let port = freePort()
  let routeFile = dir / "routes.json"
  let hits = dir / "hits.log"
  let script = dir / "registry.py"
  writeFile(routeFile, $routes)
  writeFile(hits, "")
  writeFile(script, registryPy)
  let p = startProcess(
    findExe("python3"),
    args = @[script, routeFile, hits, $port],
    options = {poUsePath, poStdErrToStdOut},
  )
  waitReady(port)
  return (p, port, hits)

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

proc route(status: int, body: string, headers: JsonNode = newJObject(),
           delayMs = 0): JsonNode =
  result = %*{
    "status": status,
    "body": body,
    "delay_ms": delayMs,
    "headers": headers,
  }

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
  let indexBody = indexDoc(%*[{
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "digest": attachmentDigest,
    "size": len(attachmentBody),
    "artifactType": "application/spdx+json",
  }])

  proc baseRoutes(extra: JsonNode = newJObject()): JsonNode =
    result = extra
    result["GET /v2/demo/manifests/" & imageDigest] = route(
      200, imageBody,
      %*{"Docker-Content-Digest": imageDigest,
         "Content-Type": "application/vnd.oci.image.manifest.v1+json"})
    result["HEAD /v2/demo/manifests/" & imageDigest] = route(
      200, imageBody,
      %*{"Docker-Content-Digest": imageDigest,
         "Content-Type": "application/vnd.oci.image.manifest.v1+json",
         "Content-Length": $len(imageBody)})
    result["GET /v2/demo/blobs/" & blobDigest] = route(
      200, blob, %*{"Content-Type": "application/spdx+json"})

  try:
    block happy:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexBody)
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      let (p, port, hits) = startRegistry(dir, routes)
      try:
        let outcome = collectFrom(port, imageDigest, configDigest, authFile, "")
        assertEq(expectDocument(outcome).sourceBytes, blob)
        doAssert "docker" notin readFile(dockerLog)
        let hitText = readFile(hits)
        doAssert "GET /v2/demo/referrers/" & imageDigest in hitText
        doAssert "GET /v2/demo/blobs/" & blobDigest in hitText
      finally:
        stopRegistry(p)

    block absent:
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(404, "")
      routes["GET /v2/demo/manifests/sha256-" & imageDigest[7 .. ^1]] = route(404, "")
      let (p, port, _) = startRegistry(dir, routes)
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
      let (p, port, hits) = startRegistry(dir, routes)
      try:
        assertEq(expectDocument(
          collectFrom(port, imageDigest, configDigest, authFile, "")).sourceBytes, blob)
        doAssert "sha256-" & imageDigest[7 .. ^1] in readFile(hits)
      finally:
        stopRegistry(p)

    block wrongGetDigest:
      var routes = baseRoutes()
      let corrupt = imageBody & " "
      routes["GET /v2/demo/manifests/" & imageDigest] = route(
        200, corrupt,
        %*{"Docker-Content-Digest": imageDigest,
           "Content-Type": "application/vnd.oci.image.manifest.v1+json"})
      routes["HEAD /v2/demo/manifests/" & imageDigest] = route(
        200, imageBody,
        %*{"Docker-Content-Digest": imageDigest,
           "Content-Type": "application/vnd.oci.image.manifest.v1+json",
           "Content-Length": $len(imageBody)})
      let (p, port, _) = startRegistry(dir, routes)
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
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": badDigest,
        "size": len(badAttach),
        "artifactType": "application/spdx+json",
      }]))
      routes["GET /v2/demo/manifests/" & badDigest] = route(200, badAttach)
      let (p, port, _) = startRegistry(dir, routes)
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
      let (p, port, _) = startRegistry(dir, routes)
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
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": multiDigest,
        "size": len(multi),
        "artifactType": "application/spdx+json",
      }]))
      routes["GET /v2/demo/manifests/" & multiDigest] = route(200, multi)
      let (p, port, _) = startRegistry(dir, routes)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, multiDigest),
          pdkAttachmentMismatch)
      finally:
        stopRegistry(p)

    block ambiguousAndSelect:
      let secondBlob = spdxDoc().replace("img", "img2")
      let secondBlobDigest = sha(secondBlob)
      let secondAttach = ociManifest(
        configDigest,
        "application/vnd.oci.image.manifest.v1+json",
        %*[{
          "mediaType": "application/spdx+json",
          "digest": secondBlobDigest,
          "size": len(secondBlob),
        }],
        subject = imageDigest,
        artifactType = "application/spdx+json",
      )
      let secondDigest = sha(secondAttach)
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexDoc(%*[
        {
          "mediaType": "application/vnd.oci.image.manifest.v1+json",
          "digest": attachmentDigest,
          "size": len(attachmentBody),
          "artifactType": "application/spdx+json",
        },
        {
          "mediaType": "application/vnd.oci.image.manifest.v1+json",
          "digest": secondDigest,
          "size": len(secondAttach),
          "artifactType": "application/spdx+json",
        },
      ]))
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      routes["GET /v2/demo/manifests/" & secondDigest] = route(200, secondAttach)
      routes["GET /v2/demo/blobs/" & secondBlobDigest] = route(
        200, secondBlob, %*{"Content-Type": "application/spdx+json"})
      let (p, port, _) = startRegistry(dir, routes)
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
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(200, indexBody)
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      routes["GET /v2/demo/blobs/" & blobDigest] = route(200, blob & "nope")
      let (p, port, _) = startRegistry(dir, routes)
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
      let (p, port, hits) = startRegistry(dir, routes)
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
      let page2 = indexDoc(%*[{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": attachmentDigest,
        "size": len(attachmentBody),
        "artifactType": "application/spdx+json",
      }])
      var routes = baseRoutes()
      routes["GET /v2/demo/referrers/" & imageDigest] = route(
        200, indexDoc(%*[]),
        %*{"Link": "<?n=2>; rel=\"next\""})
      routes["GET /v2/demo/referrers/" & imageDigest & "?n=2"] = route(200, page2)
      routes["GET /v2/demo/manifests/" & attachmentDigest] = route(200, attachmentBody)
      let (p, port, hits) = startRegistry(dir, routes)
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
      let (p, port, _) = startRegistry(dir, routes)
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
      let (p, port, _) = startRegistry(dir, routes)
      try:
        let diag = expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, ""),
          pdkAuthFailure)
        doAssert diag.message == "registry authentication failed"
        doAssert "denied" notin diag.message
      finally:
        stopRegistry(p)

    block timeout:
      var routes = baseRoutes()
      routes["GET /v2/demo/manifests/" & imageDigest] = route(200, imageBody, delayMs = 1000)
      let (p, port, _) = startRegistry(dir, routes)
      try:
        discard expectDiagnostic(
          collectFrom(port, imageDigest, configDigest, authFile, "", timeoutMs = 200),
          pdkTimeout)
      finally:
        stopRegistry(p)

    doAssert "docker" notin readFile(dockerLog)
  finally:
    removeDir(dir)

main()
