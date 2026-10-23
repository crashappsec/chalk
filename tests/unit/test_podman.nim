import ../../src/podman/chalk_platform
import std/[
  options,
  os,
  posix,
  sequtils,
  strutils,
  tempfiles,
]
import ../../src/docker/dockerfile
import ../../src/norecurse
import ../../src/podman/binding
import ../../src/podman/cmdline
import ../../src/podman/exec
import ../../src/podman/host
import ../../src/podman/inject
import ../../src/podman/notice
import ../../src/podman/report
import ../../src/podman/types
import ../../src/types as chalk_types
import ../../src/utils/json
import ../../src/utils/sets
import ../../src/utils/exec

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc expectPass(args: seq[string]) =
  let route = classifyPodmanArgs(args)
  doAssert route.kind == prPassThrough, $args

proc expectQuietPass(args: seq[string]) =
  let route = classifyPodmanArgs(args)
  doAssert route.kind == prPassThrough, $args
  doAssert route.skip.isNone(), $args

proc expectSkip(args: seq[string], operation: PodmanOperation,
                kind: PodmanSkipReasonKind, flag = ""): PodmanSkip =
  let route = classifyPodmanArgs(args)
  doAssert route.kind == prPassThrough, $args
  assertEq(route.originalArgs, args)
  doAssert route.skip.isSome(), $args
  result = route.skip.get()
  assertEq(result.operation, operation)
  assertEq(result.reason.kind, kind)
  if flag != "":
    doAssert kind in {psrUnsupportedFlag, psrInvalidFlag}
    doAssert result.reason.flag.isSome()
    assertEq(string(result.reason.flag.get()), flag)

proc expectBuildRoute(args: seq[string]): PodmanRoute =
  result = classifyPodmanArgs(args)
  doAssert result.kind == prInstrument, $args
  assertEq(result.spec.originalArgs, args)

proc expectBuild(args: seq[string]) =
  let route = expectBuildRoute(args)
  assertEq(route.spec.tags.len > 0, true)

proc expectBuildUntagged(args: seq[string]) =
  let route = expectBuildRoute(args)
  assertEq(len(route.spec.tags), 0)

proc expectContainerfile(contextArg, containerfileArg: string): string =
  let selection = selectPodmanContainerfile(contextArg, containerfileArg)
  assertEq(selection.kind, pcsSelected)
  return selection.path

proc expectContainerfileRefusal(contextArg, containerfileArg: string,
                                reason: PodmanSkipReasonKind) =
  let selection = selectPodmanContainerfile(contextArg, containerfileArg)
  assertEq(selection.kind, pcsRefused)
  assertEq(selection.reason.kind, reason)

proc main() =
  assertEq(string(safeFlagName("--build-arg=TOKEN=secret").get()), "--build-arg")
  assertEq(string(safeFlagName("-tsecret").get()), "-t")
  doAssert safeFlagName("--bad\nname").isNone()
  doAssert safeFlagName("--" & repeat('a', 63)).isNone()

  expectQuietPass(@[])
  expectQuietPass(@["--help"])
  expectQuietPass(@["build", "--help"])
  expectQuietPass(@["image", "build", "--help"])
  expectQuietPass(@["ps"])
  expectQuietPass(@["--remote", "run", "image", "build"])
  expectQuietPass(@["-r", "run", "image", "build"])
  expectQuietPass(@["-r=false", "run", "image", "pull"])
  expectQuietPass(@["--connection", "connection", "run", "image", "push"])
  expectQuietPass(@["--unknown-global", "operand", "build", "."])

  let unknownArg = expectSkip(
    @["build", "--build-arg-file=TOKEN=secret", "."],
    poBuild,
    psrUnsupportedFlag,
    "--build-arg-file",
  )
  assertEq(
    formatPodmanSkip(unknownArg),
    "chalk: skipped Podman build processing: unsupported flag --build-arg-file.",
  )
  doAssert "secret" notin formatPodmanSkip(unknownArg)
  let acceptedSecret = expectBuildRoute(
    @["build", "--build-arg=TOKEN=secret", "."],
  )
  doAssert "secret" notin acceptedSecret.spec.reportArgs.join(" ")
  assertEq(acceptedSecret.spec.confidentialArgs, @[
    PodmanConfidentialArg(flag: "--build-arg", value: "TOKEN=secret"),
  ])
  discard expectSkip(@["build", "-tsecret", "."], poBuild,
                     psrUnsupportedFlag, "-t")
  discard expectBuildRoute(@["build", "--platform", "linux/arm64", "."])
  let remote = expectSkip(
    @["build", "https://user:secret@example.invalid/context.git"],
    poBuild,
    psrNonLocalContext,
  )
  doAssert "secret" notin formatPodmanSkip(remote)
  discard expectSkip(@["push"], poPush, psrOperandUnavailable)
  discard expectSkip(@["image", "pull", "image-value"], poPull,
                     psrUnsupportedCommandForm)
  discard expectSkip(@["--remote", "build", "."], poBuild,
                     psrUnsupportedFlag, "--remote")
  discard expectSkip(@["-r", "build", "."], poBuild,
                     psrUnsupportedFlag, "-r")
  discard expectSkip(@["-r=true", "image", "pull", "image-value"], poPull,
                     psrUnsupportedFlag, "-r")
  discard expectSkip(@["--connection=secret", "image", "push", "image-value"],
                     poPush, psrUnsupportedFlag, "--connection")

  expectPass(@[])
  expectPass(@["--help"])
  expectPass(@["--version"])
  expectPass(@["run", "--rm", "image"])
  expectPass(@["--remote", "build", "."])
  expectPass(@["build", "--help"])
  expectPass(@["build", "--from", "another-stage", "."])
  discard expectBuildRoute(@["build", "--platform", "linux/arm64", "."])
  expectPass(@["build", "--build-arg-file", "PASSWORD=secret", "."])
  expectPass(@["build", "-"])
  expectPass(@["build", "https://example.invalid/context.git"])
  expectPass(@["build", "--unknown-valid-in-future", "opaque", "."])
  expectPass(@["image", "build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--format", "oci", "."])
  expectPass(@["build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--format", "oci"])
  expectPass(@["build", "--file", "Containerfile", "--file", "Other",
              "--tag", "t", "--platform", "linux/amd64", "--format", "oci", "."])
  expectBuild(@["build", "--file", "Containerfile", "--tag", "t", "--tag", "other",
                "--platform", "linux/amd64", "--format", "oci", "."])
  expectPass(@["build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--platform", "linux/amd64",
              "--format", "oci", "."])
  expectPass(@["build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--format", "oci", "--format", "oci", "."])
  expectPass(@["build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--format"])
  expectPass(@["build", "--file", "-", "--tag", "t",
              "--platform", "linux/amd64", "--format", "oci", "."])
  expectPass(@["build", "--file", "Containerfile", "--tag", "t",
              "--platform", "linux/amd64", "--format", "oci", ".", "extra"])
  expectBuild(@["build", "--iidfile", "x", "--file", "Containerfile", "--tag", "t",
                "--platform", "linux/amd64", "--format", "oci", "."])
  expectBuild(@["build", "--build-context", "extra=dir", "--file", "Containerfile",
                "--tag", "t", "--platform", "linux/amd64", "--format", "oci", "."])

  expectBuild(@["build", "--file", "Containerfile", "--tag", "t",
                "--platform", "linux/amd64", "--format", "oci", "."])
  expectBuild(@["build", "-f", "Containerfile", "-t", "t",
                "--platform", "linux/amd64", "--format", "oci", "."])
  expectBuild(@["build", "--file=Containerfile", "--tag=t",
                "--platform=linux/amd64", "--format=oci", "."])
  expectBuild(@["build", "--format", "oci", "--platform", "linux/amd64",
                "--tag", "t", "--file", "Containerfile", "."])
  expectBuild(@["build", "--file", "Containerfile", "--tag", "t",
                "--platform", "linux/amd64", "--format", "oci", "--", "."])

  # Omitted options whose podman default is one we can instrument. Each of
  # these was a pass-through while all four flags were mandatory.
  expectBuild(@["build", "-t", "foo", "."])
  expectBuild(@["build", "--tag", "foo", "."])
  expectBuild(@["build", "--tag=foo", "."])
  expectBuild(@["build", "-t", "foo", "--platform", "linux/amd64", "."])
  expectBuild(@["build", "-t", "foo", "--format", "oci", "."])
  expectBuild(@["build", "-f", "Containerfile", "-t", "foo", "."])
  expectBuild(@["build", "-t", "foo", "--", "."])
  expectBuildUntagged(@["build", "."])
  expectBuildUntagged(@["build", "--platform", "linux/amd64", "."])

  # An option that IS given must still name something we can instrument.
  expectBuild(@["build", "-t", "foo", "--platform", "linux/arm64", "."])
  expectPass(@["build", "-t", "foo", "--format", "docker", "."])
  expectPass(@["build", "--format", "docker", "."])
  expectPass(@["build", "-t", "foo", "-f", "-", "."])
  expectBuild(@["build", "-t", "foo", "-t", "bar", "."])
  expectBuild(@["build", "-t", "foo", "--no-cache", "."])
  expectPass(@["build", "-t", "foo"])

  # Defaults are left unset in the spec; they are filled in later, from
  # podman's containerfile lookup and from `podman info`.
  let implied = expectBuildRoute(@["build", "-t", "foo", "."])
  assertEq(implied.spec.containerfileArg, "")
  assertEq(implied.spec.requestedPlatform, none(ChalkPlatform))
  assertEq(implied.spec.imageFormat, "")
  assertEq(implied.spec.fileValueIndex, -1)
  assertEq(implied.spec.contextArg, ".")

  # Host gate. Rootful podman -- an ordinary CI container running as root -- must
  # instrument; only os/arch and a remote service are real limits.
  proc info(os, arch: string, remote, rootless: bool): string =
    """{"host":{"os":"""" & os & """","arch":"""" & arch &
    """","serviceIsRemote":""" & $remote &
    ""","security":{"rootless":""" & $rootless & """}}}"""

  proc expectHost(raw, platform: string) =
    let checked = checkPodmanHost(raw, target = cpLinuxAmd64)
    assertEq(checked.kind, phrSupported)
    assertEq($checked.platform, platform)

  proc expectHostRefusal(raw: string, reason: PodmanSkipReasonKind) =
    let checked = checkPodmanHost(raw, target = cpLinuxAmd64)
    assertEq(checked.kind, phrRefused)
    assertEq(checked.reason.kind, reason)

  expectHost(info("linux", "amd64", false, false), "linux/amd64")
  expectHost(info("linux", "amd64", false, true), "linux/amd64")
  expectHost(info("linux", "x86_64", false, false), "linux/amd64")
  expectHostRefusal(info("linux", "arm64", false, true),
                    psrHostPlatformMismatch)
  expectHostRefusal(info("darwin", "amd64", false, true),
                    psrUnsupportedHostOs)
  expectHostRefusal(info("linux", "amd64", true, true), psrRemoteHost)
  expectHostRefusal("not json at all", psrHostInfoInvalid)
  expectHostRefusal("{}", psrHostInfoInvalid)
  # rootless absent entirely (podman omits the key in some versions)
  expectHost(
    """{"host":{"os":"linux","arch":"amd64","serviceIsRemote":false}}""",
    "linux/amd64",
  )
  expectHost("""{"host":{"os":"linux","arch":"amd64"}}""",
             "linux/amd64")
  expectHost("""{"host":{"os":"linux","arch":"amd64","serviceIsRemote":"unknown"}}""",
             "linux/amd64")
  expectHostRefusal("""{"host":{"os":2,"arch":"amd64"}}""",
                    psrHostInfoInvalid)
  expectHostRefusal("""{"host":{"os":"linux","arch":2}}""",
                    psrHostInfoInvalid)

  assertEq(formatPodmanSkip(PodmanSkip(
             operation: poBuild,
             reason: PodmanSkipReason(kind: psrIncompatibleImagePlatform),
           )),
           "chalk: skipped Podman build processing: image platform is " &
           "incompatible with the Chalk executable.")
  assertEq(formatPodmanSkip(PodmanSkip(
             operation: poBuild,
             reason: PodmanSkipReason(kind: psrUnresolvedImagePlatform),
           )),
           "chalk: skipped Podman build processing: image platform could " &
           "not be determined.")
  doAssert "arm64" notin formatPodmanSkip(PodmanSkip(
    operation: poBuild,
    reason: PodmanSkipReason(kind: psrIncompatibleImagePlatform),
  ))
  doAssert "linux/arm64-value-must-not-be-reported" notin formatPodmanSkip(
    PodmanSkip(
      operation: poBuild,
      reason: PodmanSkipReason(kind: psrUnresolvedImagePlatform),
    )
  )

  let parserNotice = formatPodmanSkip(PodmanSkip(
    operation: poBuild,
    reason: PodmanSkipReason(
      kind: psrContainerfileIssue,
      issue: ContainerfileIssue(
        kind:        cfikSyntax,
        instruction: some(ciEntrypoint),
        line:        some(7),
      ),
    ),
  ))
  assertEq(parserNotice,
           "chalk: skipped Podman build processing: Containerfile " &
           "ENTRYPOINT on line 7 could not be parsed.")
  assertEq(formatPodmanSkip(PodmanSkip(
             operation: poBuild,
             reason: PodmanSkipReason(kind: psrContainerfileIgnoreUnsupported),
           )),
           "chalk: skipped Podman build processing: Containerfile-specific " &
           "ignore file is unsupported.")
  assertEq(formatPodmanSkip(PodmanSkip(
             operation: poBuild,
             reason: PodmanSkipReason(kind: psrContainerfileOutsideContext),
           )),
           "chalk: skipped Podman build processing: Containerfile is outside " &
           "the build context.")
  assertEq(formatPodmanRetryStart(pasInstrumentedBuildRun, some(17)),
           "chalk: the instrumented Podman build exited with status 17; " &
           "retrying the original build without instrumentation.")
  assertEq(formatPodmanRetryResult(NativeRetryResult(kind: nrSucceeded)),
           "chalk: Build succeeded; Chalk did not instrument this build.")
  assertEq(formatPodmanRetryResult(NativeRetryResult(kind: nrExited,
                                                      status: 23)),
           "chalk: the native Podman retry exited with status 23; " &
           "Chalk did not instrument this build.")

  # Guard network opt-out is feature-detected on the buildah version, never
  # assumed: an older parser would reject the flag and fail every build.
  proc infoBuildah(v: string): string =
    """{"host":{"os":"linux","arch":"amd64","serviceIsRemote":false,"buildahVersion":"""" &
    v & """"}}"""

  doAssert guardCanSkipNetwork(infoBuildah("1.39.3"))
  doAssert guardCanSkipNetwork(infoBuildah("1.43.1"))
  doAssert guardCanSkipNetwork(infoBuildah("2.0.0"))
  doAssert not guardCanSkipNetwork(infoBuildah("1.39.2"))
  doAssert not guardCanSkipNetwork(infoBuildah("1.30.0"))
  doAssert not guardCanSkipNetwork(infoBuildah("0.9.9"))
  doAssert not guardCanSkipNetwork(infoBuildah(""))
  doAssert not guardCanSkipNetwork(infoBuildah("not-a-version"))
  doAssert not guardCanSkipNetwork("""{"host":{"os":"linux"}}""")
  doAssert not guardCanSkipNetwork("garbage")

  # push / pull routing
  proc expectTransfer(args: seq[string], kind: PodmanRouteKind, image: string) =
    let r = classifyPodmanArgs(args)
    assertEq(r.kind, kind)
    assertEq(r.image, image)
    assertEq(r.originalArgs, args)

  expectTransfer(@["pull", "busybox"], prPull, "busybox")
  expectTransfer(@["pull", "-q", "busybox"], prPull, "busybox")
  expectTransfer(@["pull", "--quiet", "docker.io/library/busybox:latest"],
                 prPull, "docker.io/library/busybox:latest")
  expectTransfer(@["pull", "--tls-verify=false", "reg/img"], prPull, "reg/img")
  expectTransfer(@["push", "img"], prPush, "img")
  expectTransfer(@["push", "img", "reg/dest:tag"], prPush, "img")
  expectTransfer(@["push", "--remove-signatures", "img"], prPush, "img")
  expectTransfer(@["push", "--authfile=/tmp/a", "img"], prPush, "img")
  expectTransfer(@["pull", "--", "busybox"], prPull, "busybox")

  # A bare flag we do not recognise may or may not consume the next token, so
  # the image operand cannot be identified safely.
  expectPass(@["pull", "--authfile", "/tmp/auth", "busybox"])
  expectPass(@["push", "--sign-by", "key", "img"])
  # operand counts
  expectPass(@["pull"])
  expectPass(@["push"])
  expectPass(@["pull", "a", "b"])
  expectPass(@["push", "a", "b", "c"])
  # unusable references
  expectPass(@["pull", "-"])
  expectPass(@["pull", "docker://reg/img"])
  # build routing is unaffected
  expectPass(@["image", "pull", "busybox"])
  expectBuild(@["build", "-t", "foo", "."])

  let withDash = classifyPodmanArgs(@[
    "build", "--file", "Containerfile", "--tag", "t",
    "--platform", "linux/amd64", "--format", "oci", "--", "."
  ])
  doAssert withDash.kind == prInstrument
  doAssert withDash.spec.dashDashIndex >= 0
  let ws = PodmanWorkspace(
    derivedContainerfile: "/tmp/Containerfile.chalk",
    assetContext:         "/tmp/assets",
    iidFile:              "/tmp/image.iid",
    contextName:          "chalk_abc",
  )
  let injected = makeInjectedArgs(withDash.spec, ws)
  doAssert "--build-context" in injected
  doAssert injected.find("--") > injected.find("--build-context")
  doAssert injected[^1] == "."

  let split = classifyPodmanArgs(@[
    "build", "--file", "Containerfile", "--tag", "t",
    "--platform", "linux/amd64", "--format", "oci", "."
  ])
  let injected2 = makeInjectedArgs(split.spec, ws)
  doAssert injected2[split.spec.fileValueIndex] == ws.derivedContainerfile
  doAssert "--iidfile" in injected2

  # With no --file to rewrite, the derived containerfile has to be named
  # explicitly. Indexing at fileValueIndex would be -1 here.
  let noFile = expectBuildRoute(@["build", "-t", "foo", "."])
  assertEq(noFile.spec.fileValueIndex, -1)
  let injected3 = makeInjectedArgs(noFile.spec, ws)
  doAssert "--file" in injected3
  assertEq(injected3[injected3.find("--file") + 1], ws.derivedContainerfile)
  doAssert "--build-context" in injected3
  doAssert "--iidfile" in injected3
  assertEq(injected3.count("--file"), 1)
  # Extras are appended when there is no "--", so the original argv stays intact
  # as a prefix rather than the context remaining last.
  assertEq(injected3[0 .. 3], @["build", "-t", "foo", "."])

  let customerIid = expectBuildRoute(@["build", "--iidfile", "out.iid", "-t", "foo", "."])
  assertEq(customerIid.spec.customerIidFile, "out.iid")
  let injectedCustomerIid = makeInjectedArgs(customerIid.spec, ws)
  assertEq(injectedCustomerIid.count("--iidfile"), 1)
  assertEq(injectedCustomerIid[injectedCustomerIid.find("--iidfile") + 1], "out.iid")
  doAssert ws.iidFile notin injectedCustomerIid

  let lastIid = expectBuildRoute(
    @["build", "--iidfile", "first.iid", "--iidfile=second.iid", "."],
  )
  assertEq(lastIid.spec.customerIidFile, "second.iid")

  let twoTags = expectBuildRoute(@["build", "-t", "one", "--tag=two", "."])
  assertEq(twoTags.spec.tags, @["one", "two"])
  assertEq(primaryTag(twoTags.spec), "one")

  let pullBare = expectBuildRoute(@["build", "--pull", "."])
  assertEq(pullBare.spec.pullPolicy, bppAlways)
  assertEq(pullBare.spec.contextArg, ".")
  assertEq(pullBare.spec.originalArgs, @["build", "--pull", "."])

  let pullNever = expectBuildRoute(@["build", "--pull=never", "-t", "foo", "."])
  assertEq(pullNever.spec.pullPolicy, bppNever)
  let pullNewer = expectBuildRoute(@["build", "--pull=newer", "."])
  assertEq(pullNewer.spec.pullPolicy, bppNewer)
  let pullMissing = expectBuildRoute(@["build", "--pull=missing", "."])
  assertEq(pullMissing.spec.pullPolicy, bppMissing)
  discard expectSkip(@["build", "--pull", "always", "."], poBuild,
                     psrOperandUnavailable)
  discard expectSkip(@["build", "--pull=true", "."], poBuild,
                     psrInvalidFlag, "--pull")
  discard expectSkip(@["build", "--pull=false", "."], poBuild,
                     psrInvalidFlag, "--pull")
  discard expectSkip(@["build", "--pull=bogus", "."], poBuild,
                     psrInvalidFlag, "--pull")
  discard expectSkip(@["build", "--layers", "false", "."], poBuild,
                     psrOperandUnavailable)
  let layersFalse = expectBuildRoute(@["build", "--layers=false", "."])
  assertEq(layersFalse.spec.originalArgs, @["build", "--layers=false", "."])
  expectBuildUntagged(@["build", "--no-cache", "--quiet", "--rm", "--force-rm",
                        "--squash", "."])
  expectBuildUntagged(@["build", "--no-cache=true", "--layers=false",
                        "--rm=false", "--force-rm=false", "-q=true", "."])
  discard expectSkip(@["build", "--layers=maybe", "."], poBuild,
                     psrInvalidFlag, "--layers")
  discard expectSkip(@["build", "--target"], poBuild, psrInvalidFlag, "--target")
  discard expectSkip(@["build", "--target="], poBuild, psrInvalidFlag, "--target")
  discard expectSkip(@["build", "--target", "a", "--target", "b", "."],
                     poBuild, psrInvalidFlag, "--target")
  discard expectSkip(@["build", "--build-context", "assets", "."],
                     poBuild, psrInvalidFlag, "--build-context")
  discard expectSkip(@["build", "--build-context", "a=dir",
                       "--build-context", "a=other", "."],
                     poBuild, psrInvalidFlag, "--build-context")
  let named = expectBuildRoute(
    @["build", "--build-context", "tools=./tools",
      "--build-context=vendor=docker-image://user:pass@example.invalid/img",
      "--secret", "id=token,src=/run/secret-file",
      "--ssh=default=/run/ssh-key",
      "--env", "TOKEN=env-secret",
      "--label", "public=ok", "."],
  )
  assertEq(named.spec.contextNames, @["tools", "vendor"])
  assertEq(named.spec.originalArgs[named.spec.originalArgs.find("--secret") + 1],
           "id=token,src=/run/secret-file")
  doAssert "pass" notin named.spec.reportArgs.join(" ")
  doAssert "secret-file" notin named.spec.reportArgs.join(" ")
  doAssert "ssh-key" notin named.spec.reportArgs.join(" ")
  doAssert "env-secret" notin named.spec.reportArgs.join(" ")
  doAssert "public=ok" in named.spec.reportArgs.join(" ")
  let secretSkip = expectSkip(
    @["build", "--secret", "id=token,src=/run/secret-file", "--from", "base", "."],
    poBuild, psrUnsupportedFlag, "--from",
  )
  doAssert "secret-file" notin formatPodmanSkip(secretSkip)
  let targetBuild = expectBuildRoute(@["build", "--target", "runtime", "."])
  assertEq(targetBuild.spec.target, "runtime")
  let targetEquals = expectBuildRoute(@["build", "--target=runtime", "."])
  assertEq(targetEquals.spec.target, "runtime")

  let commandConfidential = @[
    PodmanConfidentialArg(flag: "--build-arg", value: "TOKEN=secret"),
  ]
  for whitespace in ["\t", "\n", "  "]:
    assertEq(
      redactPodmanArgv(
        @["sh", "-c", "podman build --build-arg" & whitespace &
          "TOKEN=secret ."],
        commandConfidential,
      ),
      @["sh", "-c", redactedArgText],
    )
  assertEq(
    redactPodmanArgv(
      @["sh", "-c", "podman build --build-arg\ta a image-a",
        "sha256:aaaaaaaa"],
      @[PodmanConfidentialArg(flag: "--build-arg", value: "a")],
    ),
    @["sh", "-c", redactedArgText, redactedArgText],
  )

  let confidentialReport = expectBuildRoute(
    @[
      "build", "--build-arg", "CONTEXT=.", "--env", "TOKEN=secret", ".",
    ],
  )
  assertEq(confidentialReport.spec.originalArgs,
           @["build", "--build-arg", "CONTEXT=.", "--env", "TOKEN=secret",
             "."])
  let reportFields = chalk_types.ChalkDict()
  reportFields["PODMAN_IMAGE_ID"] = chalk_types.pack("sha256:aaaaaaaa")
  reportFields["DOCKER_FILE"] = chalk_types.pack(
    "FROM alpine:3.20\nRUN printf a > /application\n",
  )
  reportFields["INJECTOR_ARGV"] = chalk_types.pack(
    @["build", "--build-arg", "CONTEXT=.", "--env", "TOKEN=secret"],
  )
  reportFields["_ARGV"] = chalk_types.pack(
    @["build", "--build-arg=CONTEXT=.", "--env=TOKEN=secret"],
  )
  reportFields["_OP_ARGV"] = chalk_types.pack(
    @["/chalk", "podman", "build", "--build-arg", "CONTEXT=."],
  )
  reportFields["_PROCESS_ARGV"] = chalk_types.pack(
    @["native-build", "a", "secret"],
  )
  reportFields["_OP_ANCESTOR_ARGVS"] = chalk_types.pack(
    @[@["/bin/sh", "-c", "podman build --env\tTOKEN=secret ."]],
  )
  let process = chalk_types.ChalkDict()
  process["argv"] = chalk_types.pack(
    @["podman", "build", "--env", "TOKEN=secret"],
  )
  let processes = chalk_types.ChalkDict()
  processes["42"] = chalk_types.pack(process)
  reportFields["_OP_ALL_PS_INFO"] = chalk_types.pack(processes)

  redactPodmanReportFields(reportFields,
                          confidentialReport.spec.confidentialArgs)

  assertEq(
    chalk_types.unpack[string](reportFields["PODMAN_IMAGE_ID"]),
    "sha256:aaaaaaaa",
  )
  assertEq(
    chalk_types.unpack[string](reportFields["DOCKER_FILE"]),
    "FROM alpine:3.20\nRUN printf a > /application\n",
  )
  assertEq(
    chalk_types.unpack[seq[string]](reportFields["_PROCESS_ARGV"]),
    @["native-build", "a", "secret"],
  )
  assertEq(
    chalk_types.unpack[seq[string]](reportFields["INJECTOR_ARGV"]),
    @["build", "--build-arg", redactedArgText, "--env", redactedArgText],
  )
  assertEq(
    chalk_types.unpack[seq[string]](reportFields["_ARGV"]),
    @["build", "--build-arg=" & redactedArgText,
      "--env=" & redactedArgText],
  )
  assertEq(
    chalk_types.unpack[seq[string]](reportFields["_OP_ARGV"]),
    @["/chalk", "podman", "build", "--build-arg", redactedArgText],
  )
  assertEq(
    chalk_types.unpack[seq[seq[string]]](
      reportFields["_OP_ANCESTOR_ARGVS"],
    ),
    @[@["/bin/sh", "-c", redactedArgText]],
  )
  let redactedAllProcesses = chalk_types.unpack[chalk_types.ChalkDict](
    reportFields["_OP_ALL_PS_INFO"],
  )
  let redactedAllProcess = chalk_types.unpack[chalk_types.ChalkDict](
    redactedAllProcesses["42"],
  )
  assertEq(
    chalk_types.unpack[seq[string]](redactedAllProcess["argv"]),
    @["podman", "build", "--env", redactedArgText],
  )
  let fallbackNotice = formatPodmanSkip(PodmanSkip(
    operation: poBuild,
    reason: PodmanSkipReason(kind: psrUnsupportedFlag,
                             flag: safeFlagName("--from")),
  ))
  doAssert "secret-file" notin fallbackNotice

  var draws = @[0xaaaa'u64, 0xbbbb'u64]
  var drawIndex = 0
  proc drawName(): uint64 =
    result = draws[drawIndex]
    inc drawIndex
  let reserved = @["chalk_" & 0xaaaa'u64.toHex().toLowerAscii()].toHashSet()
  assertEq(unusedContextName(reserved, drawName),
           "chalk_" & 0xbbbb'u64.toHex().toLowerAscii())
  doAssert namedContextReplacesBase(@["alpine:3.20"], @["alpine:3.20"], "")
  doAssert namedContextReplacesBase(@["deps"], @["alpine", "deps"], "runtime")
  doAssert namedContextReplacesBase(@["runtime"], @["alpine"], "runtime")
  doAssert not namedContextReplacesBase(@["alpine"], @["alpine:3.20"], "")
  doAssert not namedContextReplacesBase(@["scratch"], @["scratch"], "")
  doAssert not namedContextReplacesBase(@["tools"], @["alpine"], "runtime")

  # Same, but the extras must still land ahead of a "--" terminator.
  let noFileDash = expectBuildRoute(@["build", "-t", "foo", "--", "."])
  let injected4 = makeInjectedArgs(noFileDash.spec, ws)
  doAssert injected4.find("--file") < injected4.find("--")
  doAssert injected4.find("--build-context") < injected4.find("--")
  doAssert injected4[^1] == "."

  proc parseOk(contents: string): FinalExecConfig =
    let parsed = getFinalExecConfig(contents)
    doAssert parsed.config.isSome(), contents & " -> " & $parsed.errors
    doAssert len(parsed.errors) == 0, contents & " -> " & $parsed.errors
    doAssert parsed.issue.isNone(), contents & " -> " & $parsed.issue
    return parsed.config.get()

  proc mustReject(contents: string) =
    let parsed = getFinalExecConfig(contents)
    doAssert parsed.config.isNone() or len(parsed.errors) > 0, contents

  proc expectIssue(contents: string, kind: ContainerfileIssueKind,
                   instruction: ContainerInstruction, line: int) =
    let parsed = getFinalExecConfig(contents)
    doAssert parsed.config.isNone(), contents
    doAssert parsed.issue.isSome(), contents
    let issue = parsed.issue.get()
    assertEq(issue.kind, kind)
    assertEq(issue.instruction, some(instruction))
    assertEq(issue.line, some(line))

  # Exec-form ENTRYPOINT, the case that already worked.
  block:
    let c = parseOk("FROM alpine\nENTRYPOINT [\"/bin/sh\", \"/app/app.sh\"]\nCMD [\"default\"]\n")
    assertEq(c.entrypoint.kind, svExec)
    assertEq(len(c.entrypoint.argv), 2)
    assertEq(c.cmd.kind, svExec)
    assertEq(c.rootImage, "alpine")
    assertEq(c.cmdInFinal, true)

  # No ENTRYPOINT at all: previously refused outright, now reported as absent
  # so the caller can inherit it from the base image.
  block:
    let c = parseOk("FROM ubuntu\nCOPY x /x\nCMD [\"/bin/bash\"]\n")
    assertEq(c.entrypoint.kind, svInherited)
    assertEq(c.cmd.kind, svExec)
    assertEq(c.rootImage, "ubuntu")
    assertEq(c.cmdInFinal, true)

  # Nothing declared at all -- everything comes from the base image.
  block:
    let c = parseOk("FROM ubuntu\nCOPY x /x\n")
    assertEq(c.entrypoint.kind, svInherited)
    assertEq(c.cmd.kind, svInherited)
    assertEq(c.rootImage, "ubuntu")
    assertEq(c.cmdInFinal, false)

  block:
    let c = parseOk("FROM alpine\nENTRYPOINT /bin/sh /app/run.sh\n")
    assertEq(c.entrypoint.kind, svShell)
    assertEq(c.entrypoint.command, "/bin/sh /app/run.sh")

  block:
    let c = parseOk("FROM alpine\nENTRYPOINT [\"/ok\"]\nCMD echo hi\n")
    assertEq(c.entrypoint.kind, svExec)
    assertEq(c.cmd.kind, svShell)
    assertEq(c.cmd.command, "echo hi")

  # SHELL is validated, but Podman startup shell form still uses /bin/sh -c.
  block:
    let c = parseOk("FROM alpine\nSHELL [\"/bin/bash\", \"-lc\"]\nENTRYPOINT run.sh\n")
    assertEq(c.entrypoint.kind, svShell)
    assertEq(c.entrypoint.command, "run.sh")

  # A later stage wins, and its own base is reported.
  block:
    let c = parseOk("FROM alpine AS b\nENTRYPOINT [\"wrong\"]\nFROM busybox\nENTRYPOINT [\"/ok\"]\n")
    assertEq(c.entrypoint.argv[0].getStr(), "/ok")
    assertEq(c.rootImage, "busybox")
    doAssert "b" in c.stageAliases

  block:
    let c = parseOk("FROM alpine AS b\nENTRYPOINT [\"/ok\"]\nFROM b\n")
    assertEq(c.rootImage, "alpine")
    assertEq(c.entrypoint.argv[0].getStr(), "/ok")

  # A same-stage CMD survives a later ENTRYPOINT.
  block:
    let c = parseOk("FROM alpine\nCMD [\"old\"]\nENTRYPOINT [\"/ok\"]\n")
    assertEq(c.cmd.kind, svExec)
    assertEq(c.cmd.argv, %*["old"])
    assertEq(c.cmdInFinal, true)

  # Still refused: nothing here can be wrapped safely.
  mustReject("FROM alpine\nENTRYPOINT []\n")
  mustReject("FROM alpine\nENTRYPOINT [\"\"]\n")
  mustReject("FROM alpine\nENTRYPOINT [\"$X\"]\n")
  mustReject("FROM alpine\nENTRYPOINT $CMD\n")
  mustReject("FROM alpine\nCMD [\"$X\"]\n")
  mustReject("FROM alpine\nSHELL [\"\"]\n")
  mustReject("ENTRYPOINT [\"/ok\"]\n")
  mustReject("FROM alpine\nENTRYPOINT [\n")

  expectIssue("FROM scratch\nENTRYPOINT [\"secret\"\n", cfikSyntax,
              ciEntrypoint, 2)
  expectIssue("FROM scratch\nSHELL [\"secret\"\nCMD echo ok\n", cfikSyntax,
              ciShell, 2)
  expectIssue("FROM scratch\nENV TOKEN=${secret-value\nCMD [\"/ok\"]\n",
              cfikSyntax, ciEnv, 2)
  expectIssue("WORKDIR /workdir-secret\nFROM scratch\nCMD [\"/ok\"]\n",
              cfikSyntax, ciWorkdir, 1)
  expectIssue("ARG TOKEN=${secret-value\nFROM $TOKEN\nCMD [\"/ok\"]\n",
              cfikVariableDependent, ciFrom, 2)
  expectIssue("FROM scratch\nENTRYPOINT [\"$TOKEN\"]\n",
              cfikVariableDependent, ciEntrypoint, 2)
  block:
    let parsed = getFinalExecConfig(
      "ARBITRARY unknown-secret\nFROM scratch\nCMD [\"/ok\"]\n",
    )
    doAssert parsed.issue.isSome()
    assertEq(parsed.issue.get().kind, cfikSyntax)
    doAssert parsed.issue.get().instruction.isNone()
    assertEq(parsed.issue.get().line, some(1))

  block:
    let parsed = getFinalExecConfig("")
    doAssert parsed.issue.isSome()
    assertEq(parsed.issue.get().kind, cfikMissingFrom)
    doAssert parsed.issue.get().instruction.isNone()
    doAssert parsed.issue.get().line.isNone()

  # A malformed ENTRYPOINT in a discarded builder stage must not reject the
  # whole file -- only the final stage is ever wrapped.
  block:
    let c = parseOk("FROM alpine AS b\nENTRYPOINT [\"$X\"]\nFROM busybox\nENTRYPOINT [\"/ok\"]\n")
    assertEq(c.entrypoint.argv[0].getStr(), "/ok")

  block:
    let last = parseOk(
      "FROM scratch AS builder\nENTRYPOINT [\"/ep-builder\"]\nCMD [\"cmd-builder\"]\n" &
      "FROM scratch AS runtime\nUSER 1000\nENTRYPOINT [\"/ep-runtime\"]\nCMD [\"cmd-runtime\"]\n",
    )
    assertEq(last.stageAlias, "runtime")
    doAssert last.injectAt.isNone()
    assertEq(last.rootImage, "scratch")
    assertEq(last.entrypoint.argv[0].getStr(), "/ep-runtime")
    doAssert last.cmdInFinal

    let middle = getFinalExecConfig(
      "FROM scratch AS builder\nENTRYPOINT [\"/ep-builder\"]\nCMD [\"cmd-builder\"]\n" &
      "FROM scratch AS runtime\nENTRYPOINT [\"/ep-runtime\"]\nCMD [\"cmd-runtime\"]\n",
      "builder",
    )
    doAssert middle.config.isSome(), $middle.errors
    let chosen = middle.config.get()
    assertEq(chosen.stageAlias, "builder")
    doAssert chosen.injectAt.isSome()
    let text = "FROM scratch AS builder\nENTRYPOINT [\"/ep-builder\"]\nCMD [\"cmd-builder\"]\n" &
               "FROM scratch AS runtime\nENTRYPOINT [\"/ep-runtime\"]\nCMD [\"cmd-runtime\"]\n"
    assertEq(text[chosen.injectAt.get() .. chosen.injectAt.get() + 3], "FROM")
    assertEq(chosen.entrypoint.argv[0].getStr(), "/ep-builder")
    assertEq(chosen.cmd.argv[0].getStr(), "cmd-builder")
    doAssert chosen.cmdInFinal

    let namedLast = getFinalExecConfig(text, "runtime")
    doAssert namedLast.config.isSome()
    doAssert namedLast.config.get().injectAt.isNone()
    assertEq(namedLast.config.get().stageAlias, "runtime")

    let missing = getFinalExecConfig(text, "no-such-stage")
    doAssert missing.config.isNone()
    assertEq(missing.issue.get().kind, cfikTargetUnavailable)

    let numeric = getFinalExecConfig(text, "0")
    doAssert numeric.config.isNone()
    assertEq(numeric.issue.get().kind, cfikTargetUnavailable)

    let crlf = "FROM scratch AS a\r\nCMD [\"a\"]\r\nFROM scratch AS b\r\n"
    let crlfParsed = getFinalExecConfig(crlf, "a")
    doAssert crlfParsed.config.isSome()
    let crlfAt = crlfParsed.config.get().injectAt.get()
    assertEq(crlf[crlfAt .. crlfAt + 3], "FROM")
    assertEq(crlf[crlfAt - 2 .. crlfAt + 3], "\r\nFROM")

    let heredoc = getFinalExecConfig(
      "FROM scratch AS a\nRUN <<EOF\necho hi\nEOF\nFROM scratch AS b\n",
      "a",
    )
    doAssert heredoc.config.isNone()
    assertEq(heredoc.issue.get().kind, cfikUnsupportedForm)

    let escapeDir = getFinalExecConfig(
      "# escape=`\nFROM scratch AS a\nCMD [\"a\"]\nFROM scratch AS b\n",
      "a",
    )
    doAssert escapeDir.config.isNone()
    assertEq(escapeDir.issue.get().kind, cfikUnsupportedForm)

    let continued = getFinalExecConfig(
      "FROM scratch AS a\nRUN echo hi \\\n\nFROM scratch AS b\n",
      "a",
    )
    doAssert continued.config.isNone()
    assertEq(continued.issue.get().kind, cfikUnsupportedForm)

    let laterBad = getFinalExecConfig(
      "FROM scratch AS a\nENTRYPOINT [\"/ok\"]\nFROM scratch AS b\nENTRYPOINT [\"$X\"]\n",
      "a",
    )
    doAssert laterBad.config.isSome(), $laterBad.errors
    assertEq(laterBad.config.get().entrypoint.argv[0].getStr(), "/ok")

    let inherited = getFinalExecConfig(
      "FROM example/base AS base\nCMD [\"old\"]\nENTRYPOINT [\"/ok\"]\nFROM base AS runtime\n",
      "runtime",
    )
    doAssert inherited.config.isSome()
    doAssert not inherited.config.get().cmdInFinal
    assertEq(inherited.config.get().chainRefs, @["example/base", "base"])
    assertEq(inherited.config.get().rootImage, "example/base")

  doAssert isCancellation(ChildResult(kind: ceSignaled, signal: 2))
  doAssert isCancellation(ChildResult(kind: ceExited, exitCode: 130))
  doAssert isCancellation(ChildResult(kind: ceExited, exitCode: 143))
  doAssert isCancellation(ChildResult(kind: ceExited, exitCode: 0, forwardedSignal: 15))
  doAssert not isCancellation(ChildResult(kind: ceExited, exitCode: 17))
  doAssert not isCancellation(ChildResult(kind: ceSpawnFailed, exitCode: 127))
  assertEq(cancellationExit(ChildResult(kind: ceSignaled, signal: 2)), 130)
  assertEq(childStatus(ChildResult(kind: ceExited, exitCode: 17)), 17)

  when defined(posix):
    for code in [130, 143]:
      let pid = fork()
      doAssert pid >= 0
      if pid == 0:
        quitChalkWithStatus(code)
      var status: cint
      while waitpid(pid, status, 0) < 0:
        doAssert errno == EINTR
      doAssert WIFEXITED(status)
      assertEq(WEXITSTATUS(status), code)

  const marker = "__CHALK_INVOCATIONS__"
  let
    markerExisted = existsEnv(marker)
    markerValue   = getEnv(marker)
  try:
    putEnv(marker, "not-a-number")
    recursionCheck()
    assertEq(getEnv(marker), "1")
    restoreChalkRecursionMarker()
    assertEq(getEnv(marker), "not-a-number")
    restoreChalkRecursionMarker()
    assertEq(getEnv(marker), "not-a-number")
  finally:
    if markerExisted:
      putEnv(marker, markerValue)
    else:
      delEnv(marker)

  let source = createTempDir("podman-source-", "")
  try:
    let markerPath = source / "customer-file"
    writeFile(markerPath, "unchanged\n")
    let
      tmpExisted = existsEnv("TMPDIR")
      tmpValue   = getEnv("TMPDIR")
    try:
      putEnv("TMPDIR", source)
      let
        scratchConfig = getFinalExecConfig(
          "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n",
        ).config.get()
        testBinding = BaseBinding(
          kind: bbConfigId,
          configId: repeat('a', 64),
        )
      let workspace = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n",
        startup:             scratchConfig,
        startupPlan:        some(StartupPlan(
          entrypoint: parseJson("[\"/bin/true\"]"),
          binding:    BaseBinding(kind: bbScratch),
        )),
        resolvedContext:    source,
      ))
      doAssert workspace.isSome()
      let
        sourcePath    = normalizedPath(expandFilename(source))
        workspacePath = normalizedPath(expandFilename(workspace.get().root))
      doAssert workspacePath != sourcePath
      doAssert not workspacePath.startsWith(sourcePath & $DirSep)
      let
        reservedGuard = "RUN [\"/bin/sh\", \"-c\", \"test -x / && " &
          "test ! -L /chalk && test ! -L /chalk.json && " &
          "{ { test ! -e /chalk && test ! -e /chalk.json; } || " &
          "grep -q dadfedabbadabbed /chalk.json; }\"]"
        firstCopy = workspace.get().derivedText.find("COPY --from=")
      doAssert reservedGuard in workspace.get().derivedText
      doAssert workspace.get().derivedText.find(reservedGuard) < firstCopy
      assertEq(getFilePermissions(workspace.get().root), {
        fpUserRead, fpUserWrite, fpUserExec,
      })
      assertEq(readFile(markerPath), "unchanged\n")
      assertEq(toSeq(walkDir(source)).len, 1)

      # Default spec: plain RUN, exactly as before.
      doAssert "RUN --network=none" notin workspace.get().derivedText

      # guardNoNetwork set: the flag rides on our guard and nothing else.
      let netWorkspace = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n",
        startup:             scratchConfig,
        startupPlan:        some(StartupPlan(
          entrypoint: parseJson("[\"/bin/true\"]"),
          binding:    BaseBinding(kind: bbScratch),
        )),
        resolvedContext:    source,
        guardNoNetwork:     true,
      ))
      doAssert netWorkspace.isSome()
      let netText = netWorkspace.get().derivedText
      doAssert "RUN --network=none [\"/bin/sh\", \"-c\", \"test -x / && " in netText
      assertEq(netText.count("--network=none"), 1)
      # the customer's own instructions are untouched
      doAssert "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n" in netText

      # An entrypoint inherited from a chalked base is left alone, but the
      # binary and mark are still refreshed -- that is what re-chalking means.
      let wrappedWs = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: "FROM acme/chalked\n",
        startup:           getFinalExecConfig("FROM acme/chalked\n").config.get(),
        startupPlan:        some(StartupPlan(
          entrypoint:     parseJson("[\"/chalk\",\"exec\",\"--heartbeat\",\"--\"]"),
          alreadyWrapped: true,
          binding:        testBinding,
        )),
        resolvedContext:    source,
      ))
      doAssert wrappedWs.isSome()
      let wrappedText = wrappedWs.get().derivedText
      doAssert "ENTRYPOINT" notin wrappedText
      doAssert "COPY --from=" in wrappedText
      doAssert "chalk.json /chalk.json" in wrappedText

      # No ENTRYPOINT anywhere: bare `chalk exec` wrapper, and a CMD that came
      # from the base image has to be restated because ENTRYPOINT resets it.
      let cmdWs = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: "FROM ubuntu\n",
        startup:           getFinalExecConfig("FROM ubuntu\n").config.get(),
        startupPlan:        some(StartupPlan(
          cmd:     parseJson("[\"/bin/bash\"]"),
          emitCmd: true,
          binding: testBinding,
        )),
        resolvedContext:    source,
      ))
      doAssert cmdWs.isSome()
      let cmdText = cmdWs.get().derivedText
      doAssert "ENTRYPOINT [\"/chalk\",\"exec\",\"--heartbeat\",\"--\"]" in cmdText
      doAssert "CMD [\"/bin/bash\"]" in cmdText

      # Same, but the final stage declared the CMD itself, so it is already in
      # the file and must not be duplicated.
      let noCmdWs = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: "FROM ubuntu\nCMD [\"/bin/bash\"]\n",
        startup:           getFinalExecConfig(
          "FROM ubuntu\nCMD [\"/bin/bash\"]\n",
        ).config.get(),
        startupPlan:        some(StartupPlan(
          cmd:     parseJson("[\"/bin/bash\"]"),
          binding: testBinding,
        )),
        resolvedContext:    source,
      ))
      doAssert noCmdWs.isSome()
      assertEq(noCmdWs.get().derivedText.count("CMD "), 1)

      let spliceText = "FROM scratch AS chosen\r\nCMD [\"chosen\"]\r\nFROM scratch AS other\r\n"
      let spliceParsed = getFinalExecConfig(spliceText, "chosen")
      doAssert spliceParsed.config.isSome()
      let spliceWs = preparePodmanBuild(PodmanBuildSpec(
        containerfileText: spliceText,
        startup:           spliceParsed.config.get(),
        startupPlan:       some(StartupPlan(
          entrypoint: parseJson("[\"/bin/true\"]"),
          emitCmd:    true,
          cmd:        parseJson("[\"chosen\"]"),
          binding:    BaseBinding(kind: bbScratch),
        )),
        resolvedContext:   source,
      ))
      doAssert spliceWs.isSome()
      let derived = spliceWs.get().derivedText
      doAssert derived.startsWith("FROM scratch AS chosen\r\nCMD [\"chosen\"]\r\n")
      doAssert derived.endsWith("FROM scratch AS other\r\n")
      doAssert "COPY --from=" in derived
      doAssert derived.find("COPY --from=") < derived.find("FROM scratch AS other")
      let prefix = spliceText[0 ..< spliceParsed.config.get().injectAt.get()]
      let suffix = spliceText[spliceParsed.config.get().injectAt.get() .. ^1]
      assertEq(derived[0 ..< len(prefix)], prefix)
      assertEq(derived[len(derived) - len(suffix) .. ^1], suffix)
    finally:
      if tmpExisted:
        putEnv("TMPDIR", tmpValue)
      else:
        delEnv("TMPDIR")
  finally:
    removeDir(source)

  let collisionRoot = createTempDir("podman-containerfile-", "")
  let previousDir = getCurrentDir()
  try:
    let context = collisionRoot / "context"
    createDir(context)
    writeFile(collisionRoot / "Containerfile", "FROM wrong\n")
    writeFile(context / "Containerfile", "FROM expected\n")
    setCurrentDir(collisionRoot)
    expectContainerfileRefusal(context, "Containerfile",
                               psrContainerfileOutsideContext)
    setCurrentDir(context)
    let selected = expectContainerfile(".", "Containerfile")
    assertEq(readFile(selected), "FROM expected\n")
    writeFile("Containerfile.containerignore", "excluded\n")
    expectContainerfileRefusal(".", "Containerfile",
                               psrContainerfileIgnoreUnsupported)
    removeFile("Containerfile.containerignore")
    writeFile("Containerfile.dockerignore", "excluded\n")
    expectContainerfileRefusal(".", "Containerfile",
                               psrContainerfileIgnoreUnsupported)
    removeFile("Containerfile.dockerignore")
    when defined(posix):
      createSymlink("Containerfile", "Containerfile.alias")
      writeFile("Containerfile.alias.containerignore", "excluded\n")
      expectContainerfileRefusal(".", "Containerfile.alias",
                                 psrContainerfileIgnoreUnsupported)

    # Implied containerfile: podman probes Containerfile then Dockerfile in the
    # context root, and resolves them against the context rather than the cwd.
    let implied = collisionRoot / "implied"
    createDir(implied)
    setCurrentDir(collisionRoot)
    expectContainerfileRefusal(implied, "", psrContainerfileUnavailable)
    writeFile(implied / "Dockerfile", "FROM dockerfile\n")
    let onlyDockerfile = expectContainerfile(implied, "")
    assertEq(readFile(onlyDockerfile), "FROM dockerfile\n")
    writeFile(implied / "Containerfile", "FROM containerfile\n")
    let bothPresent = expectContainerfile(implied, "")
    assertEq(readFile(bothPresent), "FROM containerfile\n")
    # A sidecar ignore on the file podman would build must pass the build
    # through, never silently select the other name.
    writeFile(implied / "Containerfile.containerignore", "excluded\n")
    expectContainerfileRefusal(implied, "",
                               psrContainerfileIgnoreUnsupported)
    removeFile(implied / "Containerfile.containerignore")
    discard expectContainerfile(implied, "")
    # A Containerfile in the cwd must not be picked up for another context.
    setCurrentDir(context)
    let fromOtherDir = expectContainerfile(implied, "")
    assertEq(readFile(fromOtherDir), "FROM containerfile\n")
    setCurrentDir(collisionRoot)
    # A directory named Containerfile is not a containerfile.
    let dirNamed = collisionRoot / "dir-named"
    createDir(dirNamed)
    createDir(dirNamed / "Containerfile")
    expectContainerfileRefusal(dirNamed, "", psrContainerfileUnavailable)
    writeFile(dirNamed / "Dockerfile", "FROM fallback\n")
    let skipsDir = expectContainerfile(dirNamed, "")
    assertEq(readFile(skipsDir), "FROM fallback\n")
    setCurrentDir(context)

    let nested = context / "nested"
    createDir(nested)
    writeFile(nested / "Containerfile", "FROM nested\n")
    setCurrentDir(nested)
    discard expectContainerfile("..", "Containerfile")
    writeFile(context / "Containerfile.containerignore", "excluded\n")
    expectContainerfileRefusal("..", "Containerfile",
                               psrContainerfileIgnoreUnsupported)
  finally:
    setCurrentDir(previousDir)
    removeDir(collisionRoot)

  proc writeFakeLinuxAmd64(path: string) =
    var hdr = newString(20)
    hdr[0] = '\x7f'
    hdr[1] = 'E'
    hdr[2] = 'L'
    hdr[3] = 'F'
    hdr[4] = '\x02'
    hdr[5] = '\x01'
    hdr[6] = '\x01'
    hdr[18] = '\x3e'
    hdr[19] = '\x00'
    writeFile(path, hdr)

  let inputRoot = createTempDir("podman-input-result-", "")
  try:
    let fakeElf = inputRoot / "linux-amd64-elf"
    writeFakeLinuxAmd64(fakeElf)
    writeFile(inputRoot / "Containerfile",
              "FROM alpine:3.20 AS runtime\nENTRYPOINT [\"/ok\"]\n")
    let colliding = expectBuildRoute(
      @["build", "--build-context", "alpine:3.20=docker-image://other",
        inputRoot],
    )
    var checked = resolvePodmanInputs(colliding.spec, fakeElf)
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrInvalidFlag)
    assertEq(string(checked.reason.flag.get()), "--build-context")
    doAssert "docker-image" notin formatPodmanSkip(PodmanSkip(
      operation: poBuild, reason: checked.reason,
    ))

    let aliasColliding = expectBuildRoute(
      @["build", "--build-context", "runtime=./tools", "--target", "runtime",
        inputRoot],
    )
    checked = resolvePodmanInputs(aliasColliding.spec, fakeElf)
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrInvalidFlag)

    let copyContext = expectBuildRoute(
      @["build", "--build-context", "tools=./tools", inputRoot],
    )
    checked = resolvePodmanInputs(copyContext.spec, fakeElf)
    assertEq(checked.kind, pirResolved)
    doAssert "tools" in checked.spec.contextNames
    removeFile(inputRoot / "Containerfile")

    let inputRoute = expectBuildRoute(@["build", inputRoot])

    checked = resolvePodmanInputs(inputRoute.spec)
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrContainerfileUnavailable)

    writeFile(inputRoot / "Containerfile",
              "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n")
    checked = resolvePodmanInputs(inputRoute.spec, fakeElf)
    assertEq(checked.kind, pirResolved)
    assertEq(checked.spec.resolvedContext,
             normalizedPath(expandFilename(inputRoot)))

    checked = resolvePodmanInputs(inputRoute.spec, inputRoot / "Containerfile")
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrBinaryIncompatible)

    writeFile(inputRoot / "Containerfile",
              "FROM scratch\nENTRYPOINT [\"secret\"\n")
    checked = resolvePodmanInputs(inputRoute.spec, fakeElf)
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrContainerfileIssue)
    assertEq(checked.reason.issue.instruction, some(ciEntrypoint))
    assertEq(checked.reason.issue.line, some(2))

    let missingRoute = expectBuildRoute(@["build", inputRoot / "missing"])
    checked = resolvePodmanInputs(missingRoute.spec)
    assertEq(checked.kind, pirRefused)
    assertEq(checked.reason.kind, psrContextUnavailable)
  finally:
    removeDir(inputRoot)

main()
