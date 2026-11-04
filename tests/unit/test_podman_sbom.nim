import std/[
  json,
  monotimes,
  options,
  os,
  posix,
  strutils,
  tempfiles,
  times,
]
import ../../src/podman/run
import ../../src/podman/sbom
import ../../src/podman/types
import ../../src/types

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

proc spdxDoc(packages = "[]", version = "SPDX-2.3"): string =
  """{"spdxVersion":"""" & version &
  """","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"img",""" &
  """"documentNamespace":"https://example.com/spdx/img",""" &
  """"creationInfo":{"created":"2024-01-01T00:00:00Z","creators":["Tool: test"]},""" &
  """"packages":""" & packages & "}"

proc writeFakePodman(dir, imageFile, logFile: string, createSleepSec = ""): string =
  result = dir / "fake-podman"
  var body = "#!/bin/sh\n"
  body &= "log=\"$CHALK_FAKE_PODMAN_LOG\"\n"
  body &= "echo \"$1\" >> \"$log\"\n"
  body &= "cmd=\"$1\"\n"
  body &= "shift\n"
  body &= "case \"$cmd\" in\n"
  body &= "  create)\n"
  body &= "    echo ctr-$$\n"
  if createSleepSec != "":
    body &= "    sleep " & createSleepSec & "\n"
  body &= "    ;;\n"
  body &= "  cp)\n"
  body &= "    dest=\"$2\"\n"
  body &= "    if [ ! -f \"$CHALK_FAKE_IMAGE_SBOM\" ]; then exit 1; fi\n"
  body &= "    cp \"$CHALK_FAKE_IMAGE_SBOM\" \"$dest\"\n"
  body &= "    ;;\n"
  body &= "  rm)\n"
  body &= "    echo rm >> \"$log\"\n"
  body &= "    ;;\n"
  body &= "  *)\n"
  body &= "    exit 127\n"
  body &= "    ;;\n"
  body &= "esac\n"
  writeFile(result, body)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpOthersRead})
  putEnv("CHALK_FAKE_PODMAN_LOG", logFile)
  putEnv("CHALK_FAKE_IMAGE_SBOM", imageFile)

proc main() =
  doAssert not hasExistingPodmanIdentity(nil)
  doAssert not hasExistingPodmanIdentity(ChalkObj())
  let existingMark = ChalkDict()
  let existing = ChalkObj(extract: existingMark)
  doAssert not hasExistingPodmanIdentity(existing)
  existingMark["CHALK_ID"] = pack("existing-chalk")
  doAssert not hasExistingPodmanIdentity(existing)
  existingMark["METADATA_ID"] = pack("existing-build-metadata")
  doAssert hasExistingPodmanIdentity(existing)
  existingMark["METADATA_ID"] = pack(12)
  doAssert not hasExistingPodmanIdentity(existing)
  doAssert hasNativeSbomDocument(PodmanSbomNativeOutputs(hostOutput: "a.json"))
  doAssert hasNativeSbomDocument(PodmanSbomNativeOutputs(imageOutput: "/sbom.json"))
  doAssert not hasNativeSbomDocument(PodmanSbomNativeOutputs(preset: "syft"))
  doAssert not hasNativeSbomDocument(PodmanSbomNativeOutputs(purlHostOutput: "p.json"))

  doAssert isStreamDestination("-")
  doAssert isStreamDestination("/dev/stdout")
  doAssert isStreamDestination("/dev/stderr")
  doAssert isStreamDestination("/dev/fd/1")
  doAssert not isStreamDestination("sbom.json")
  doAssert not isStreamDestination("/tmp/sbom.json")

  let parsed23 = expectDocument(parsePodmanSpdx(spdxDoc(), pskNative))
  assertEq(parsed23.parsed{"spdxVersion"}.getStr(), "SPDX-2.3")
  assertEq(parsed23.sourceBytes, spdxDoc())
  assertEq(len(parsed23.sourceSha256), 64)
  discard expectDocument(parsePodmanSpdx(spdxDoc(version = "SPDX-2.2"), pskHandoff))
  discard expectDocument(parsePodmanSpdx(spdxDoc(packages = "[]"), pskNative))
  discard expectDiagnostic(parsePodmanSpdx("{", pskNative), pdkMalformed)
  discard expectDiagnostic(parsePodmanSpdx("[]", pskNative), pdkMalformed)
  discard expectDiagnostic(
    parsePodmanSpdx("""{"bomFormat":"CycloneDX","specVersion":"1.5"}""", pskNative),
    pdkUnsupportedFormat,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-3.0","SPDXID":"SPDXRef-DOCUMENT"}""",
                    pskNative),
    pdkUnsupportedFormat,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"name":"no-version"}""", pskNative),
    pdkUnsupportedFormat,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-2.3"}""", pskNative),
    pdkMalformed,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("x".repeat(maxPodmanSbomBytes + 1), pskNative),
    pdkOversized,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"img","packages":[]}""",
                    pskNative),
    pdkMalformed,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"img","documentNamespace":"https://example.com/ns","creationInfo":{"created":"2024-01-01T00:00:00Z","creators":[]},"packages":[]}""",
                    pskNative),
    pdkMalformed,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"img","documentNamespace":"https://example.com/ns","creationInfo":"nope","packages":[]}""",
                    pskNative),
    pdkMalformed,
  )
  discard expectDiagnostic(
    parsePodmanSpdx("""{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"img","documentNamespace":"https://example.com/ns","creationInfo":{"created":"2024-01-01T00:00:00Z","creators":["Tool: test"]},"packages":{}}""",
                    pskNative),
    pdkMalformed,
  )
  let emptyOk = expectDocument(parsePodmanSpdx(spdxDoc(packages = "[]"), pskNative))
  assertEq(emptyOk.parsed{"packages"}.len, 0)
  assertEq(emptyOk.sourceBytes, spdxDoc(packages = "[]"))

  doAssert parseSha256Digest("sha256:" & "a".repeat(64)) == "sha256:" & "a".repeat(64)
  doAssert parseSha256Digest("A".repeat(64)) == "sha256:" & "a".repeat(64)
  doAssert parseSha256Digest("sha256:abc") == ""
  doAssert parseSha256Digest("sha512:" & "a".repeat(64)) == ""
  doAssert parsePodmanRegistryReference("example.com/repo:tag").isNone()
  doAssert parsePodmanRegistryReference("example.com/repo@sha256:abcd").isNone()
  doAssert parsePodmanRegistryReference("example.com/repo@" & "a".repeat(64)).isNone()
  doAssert parsePodmanRegistryReference(
    "example.com/repo@sha256:" & "a".repeat(64)).isSome()
  doAssert parsePodmanRegistryReference(
    "example.com/repo@sha512:" & "a".repeat(64)).isNone()

  let missing = snapshotHostFile("/no/such/sbom-chalk-unit")
  doAssert not missing.existed
  let tmpDir = createTempDir("chalk-sbom-", "")
  try:
    let path = tmpDir / "sbom.json"
    let beforeMissing = snapshotHostFile(path)
    writeFile(path, spdxDoc())
    let afterCreate = snapshotHostFile(path)
    doAssert hostOutputFresh(beforeMissing, afterCreate)
    let beforeExisting = snapshotHostFile(path)
    doAssert not hostOutputFresh(beforeExisting, snapshotHostFile(path))
    sleep(20)
    writeFile(path, spdxDoc())
    doAssert hostOutputFresh(beforeExisting, snapshotHostFile(path))
    writeFile(path, spdxDoc())
    let rewrittenSame = snapshotHostFile(path)
    doAssert hostOutputFresh(beforeExisting, rewrittenSame) or
      rewrittenSame.mtimeNs != beforeExisting.mtimeNs or
      rewrittenSame.fileId != beforeExisting.fileId
    let streamRead = readLimitedFile("/dev/stdout", getMonoTime() + initDuration(seconds = 1))
    discard expectDiagnostic(streamRead, pdkStreamDestination)
    let deadlinePast = getMonoTime() - initDuration(seconds = 1)
    discard expectDiagnostic(readLimitedFile(path, deadlinePast), pdkTimeout)
    let tooBig = tmpDir / "big.json"
    writeFile(tooBig, "x".repeat(64))
    # size gate uses the file size; a huge file is not created here.
    let parsedFile = readLimitedFile(path, getMonoTime() + initDuration(seconds = 5))
    assertEq(expectDocument(parsedFile).sourceBytes, spdxDoc())
    var cancellation = none(ChildResult)
    let native = collectNativePodmanSbom(
      exe          = "",
      imageRef     = "unused",
      outputs      = PodmanSbomNativeOutputs(hostOutput: "sbom.json"),
      snapshots    = @[beforeMissing],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = cancellation,
    )
    assertEq(expectDocument(native).sourceBytes, spdxDoc())
    let stale = collectNativePodmanSbom(
      exe          = "",
      imageRef     = "unused",
      outputs      = PodmanSbomNativeOutputs(hostOutput: "sbom.json"),
      snapshots    = @[snapshotHostFile(path)],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = cancellation,
    )
    discard expectDiagnostic(stale, pdkStale)
    let streamNative = collectNativePodmanSbom(
      exe          = "",
      imageRef     = "unused",
      outputs      = PodmanSbomNativeOutputs(hostOutput: "-"),
      snapshots    = @[],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = cancellation,
    )
    discard expectDiagnostic(streamNative, pdkStreamDestination)
    let hostA = tmpDir / "a.json"
    let hostB = tmpDir / "b.json"
    writeFile(hostA, spdxDoc())
    writeFile(hostB, spdxDoc(packages = """[{"name":"x","SPDXID":"SPDXRef-x"}]"""))

    let fifoPath = tmpDir / "fifo.spdx.json"
    discard mkfifo(cstring(fifoPath), 0o644.Mode)
    let fifoRead = readLimitedFile(fifoPath, getMonoTime() + initDuration(milliseconds = 200))
    discard expectDiagnostic(fifoRead, pdkStreamDestination)

    let logFile = tmpDir / "podman.log"
    let imageFile = tmpDir / "image.spdx.json"
    writeFile(imageFile, spdxDoc())
    writeFile(logFile, "")
    let fake = writeFakePodman(tmpDir, imageFile, logFile)

    var collectCancel = none(ChildResult)
    let hostOnly = collectNativePodmanSbom(
      exe          = fake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(hostOutput: "sbom.json"),
      snapshots    = @[beforeMissing],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = collectCancel,
    )
    assertEq(expectDocument(hostOnly).sourceBytes, spdxDoc())
    doAssert collectCancel.isNone()
    doAssert readFile(logFile).strip() == ""

    writeFile(logFile, "")
    let embedded = collectNativePodmanSbom(
      exe          = fake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(imageOutput: "/sbom.spdx.json"),
      snapshots    = @[],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = collectCancel,
    )
    assertEq(expectDocument(embedded).sourceBytes, spdxDoc())
    doAssert collectCancel.isNone()
    let embeddedLog = readFile(logFile)
    doAssert "create" in embeddedLog
    doAssert "cp" in embeddedLog
    doAssert "rm" in embeddedLog
    doAssert "syft" notin embeddedLog
    doAssert "trivy" notin embeddedLog

    writeFile(logFile, "")
    writeFile(path, spdxDoc())
    let dualOk = collectNativePodmanSbom(
      exe          = fake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(
        hostOutput: "sbom.json", imageOutput: "/sbom.spdx.json"),
      snapshots    = @[beforeMissing],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = collectCancel,
    )
    assertEq(expectDocument(dualOk).sourceBytes, spdxDoc())

    writeFile(imageFile, spdxDoc(packages = """[{"name":"x","SPDXID":"SPDXRef-x"}]"""))
    writeFile(path, spdxDoc())
    let dualMismatch = collectNativePodmanSbom(
      exe          = fake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(
        hostOutput: "sbom.json", imageOutput: "/sbom.spdx.json"),
      snapshots    = @[beforeMissing],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = collectCancel,
    )
    discard expectDiagnostic(dualMismatch, pdkInconsistent)

    writeFile(imageFile, "")
    removeFile(imageFile)
    writeFile(logFile, "")
    let missingImage = collectNativePodmanSbom(
      exe          = fake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(imageOutput: "/sbom.spdx.json"),
      snapshots    = @[],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(seconds = 5),
      cancellation = collectCancel,
    )
    discard expectDiagnostic(missingImage, pdkMissing)
    doAssert "rm" in readFile(logFile)
    doAssert collectCancel.isNone()

    let sleepFake = writeFakePodman(tmpDir, imageFile, logFile, createSleepSec = "1")
    writeFile(logFile, "")
    let timed = collectNativePodmanSbom(
      exe          = sleepFake,
      imageRef     = "img",
      outputs      = PodmanSbomNativeOutputs(imageOutput: "/sbom.spdx.json"),
      snapshots    = @[],
      workingDir   = tmpDir,
      deadline     = getMonoTime() + initDuration(milliseconds = 200),
      cancellation = collectCancel,
    )
    discard expectDiagnostic(timed, pdkTimeout)
    doAssert collectCancel.isNone()
    doAssert "rm" in readFile(logFile)

    let child = runCaptured("/bin/sleep", @["2"], timeoutMs = 200)
    doAssert child.child.timedOut
    doAssert not isCancellation(child.child)
  finally:
    removeDir(tmpDir)

  let handoffDir = createTempDir("chalk-handoff-", "")
  try:
    let docPath = handoffDir / "sbom.spdx.json"
    let bytes = spdxDoc()
    writeFile(docPath, bytes)
    let handoff = handoffDir / "handoff.json"
    writeFile(handoff, $(%*{
      "version": 1,
      "path": "sbom.spdx.json",
      "sha256": expectDocument(parsePodmanSpdx(bytes, pskNative)).sourceSha256,
      "image_id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }))
    let ok = collectHandoffPodmanSbom(
      handoff,
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      getMonoTime() + initDuration(seconds = 5),
    )
    assertEq(expectDocument(ok).sourceBytes, bytes)
    writeFile(handoff, $(%*{
      "version": 1,
      "path": "sbom.spdx.json",
      "sha256": "0".repeat(64),
      "image_id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }))
    discard expectDiagnostic(
      collectHandoffPodmanSbom(
        handoff,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        getMonoTime() + initDuration(seconds = 5),
      ),
      pdkHandoffChecksum,
    )
    writeFile(handoff, $(%*{
      "version": 1,
      "path": "sbom.spdx.json",
      "sha256": expectDocument(parsePodmanSpdx(bytes, pskNative)).sourceSha256,
      "image_id": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    }))
    discard expectDiagnostic(
      collectHandoffPodmanSbom(
        handoff,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        getMonoTime() + initDuration(seconds = 5),
      ),
      pdkHandoffImage,
    )
    writeFile(handoff, $(%*{"version": 2, "path": "x", "sha256": "a", "image_id": "b"}))
    discard expectDiagnostic(
      collectHandoffPodmanSbom(
        handoff, "b", getMonoTime() + initDuration(seconds = 5),
      ),
      pdkHandoffVersion,
    )
    let parsedHandoff = parseHandoff("""{"version":1,"path":"sbom.spdx.json","sha256":"abc","image_id":"id"}""",
                                     handoffDir)
    doAssert parsedHandoff.error.isNone()
    assertEq(parsedHandoff.handoff.path, "sbom.spdx.json")
    assertEq(resolveAgainst(parsedHandoff.handoff.path, parsedHandoff.handoff.dir),
             handoffDir / "sbom.spdx.json")
  finally:
    removeDir(handoffDir)

  let subject = "sha256:" & "a".repeat(64)
  let one = PodmanSbomAttachmentCandidate(
    digest: "sha256:" & "b".repeat(64),
    artifactType: spdxJsonMediaType,
    subjectDigest: subject,
    layerDigest: "sha256:" & "c".repeat(64),
    layerMediaType: spdxJsonMediaType,
  )
  let two = PodmanSbomAttachmentCandidate(
    digest: "sha256:" & "d".repeat(64),
    artifactType: spdxJsonMediaType,
    subjectDigest: subject,
    layerDigest: "sha256:" & "e".repeat(64),
    layerMediaType: spdxJsonMediaType,
  )
  let wrongSubject = PodmanSbomAttachmentCandidate(
    digest: "sha256:" & "f".repeat(64),
    artifactType: spdxJsonMediaType,
    subjectDigest: "sha256:" & "0".repeat(64),
    layerMediaType: spdxJsonMediaType,
  )
  doAssert candidateMatchesSpdx(one, subject)
  doAssert not candidateMatchesSpdx(wrongSubject, subject)
  doAssert not candidateMatchesSpdx(PodmanSbomAttachmentCandidate(
    digest: one.digest,
    artifactType: spdxJsonMediaType,
    subjectDigest: subject,
  ), subject)
  let absent = selectSpdxAttachment(@[], "")
  doAssert absent.error.isSome()
  assertEq(absent.error.get().kind, pdkAttachmentAbsent)
  let ambiguous = selectSpdxAttachment(@[one, two], "")
  doAssert ambiguous.error.isSome()
  assertEq(ambiguous.error.get().kind, pdkAttachmentAmbiguous)
  let picked = selectSpdxAttachment(@[one, two], two.digest)
  doAssert picked.error.isNone()
  assertEq(picked.selected.get().digest, two.digest)
  let missingPick = selectSpdxAttachment(@[one], two.digest)
  doAssert missingPick.error.isSome()
  assertEq(missingPick.error.get().kind, pdkAttachmentAbsent)
  let single = selectSpdxAttachment(@[one], "")
  doAssert single.error.isNone()
  assertEq(single.selected.get().digest, one.digest)

  assertEq(normalizeDigest("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
           "sha256:" & "a".repeat(64))
  doAssert sameImageId("sha256:" & "a".repeat(64), "a".repeat(64))
  doAssert not sameImageId("", "")
  assertEq(failedKeyCode(pdkStale), "SBOM_STALE")
  assertEq(failedKeyCode(pdkAuthFailure), "SBOM_AUTH")

main()
