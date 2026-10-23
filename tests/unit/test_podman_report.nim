##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/strutils
import ../../src/podman/cmdline
import ../../src/podman/report
import ../../src/podman/types
import ../../src/types as chalk_types

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc expectBuildRoute(args: seq[string]): PodmanRoute =
  result = classifyPodmanArgs(args)
  doAssert result.kind == prInstrument, $args
  assertEq(result.spec.originalArgs, args)

proc expectRawReportRedaction(
    confidential: openArray[PodmanConfidentialArg],
    argv, expected: seq[string],
) =
  let identity = "sha256:bbbbbbbb"
  let containerfile = "FROM scratch\nENTRYPOINT [\"/bin/true\"]\n"
  let executionArgv = @[
    "/chalk", "podman", "build", "--file", "Containerfile", ".",
  ]
  let fields = chalk_types.ChalkDict()
  fields["PODMAN_IMAGE_ID"] = chalk_types.pack(identity)
  fields["DOCKER_FILE"] = chalk_types.pack(containerfile)
  fields["_OP_ARGV"] = chalk_types.pack(executionArgv)
  fields["_OP_ANCESTOR_ARGVS"] = chalk_types.pack(
    @[argv],
  )
  let process = chalk_types.ChalkDict()
  process["argv"] = chalk_types.pack(argv)
  let processes = chalk_types.ChalkDict()
  processes["17"] = chalk_types.pack(process)
  fields["_OP_ALL_PS_INFO"] = chalk_types.pack(processes)

  redactPodmanReportFields(fields, confidential)

  assertEq(
    chalk_types.unpack[seq[seq[string]]](fields["_OP_ANCESTOR_ARGVS"]),
    @[expected],
  )
  let redactedProcesses = chalk_types.unpack[chalk_types.ChalkDict](
    fields["_OP_ALL_PS_INFO"],
  )
  let redactedProcess = chalk_types.unpack[chalk_types.ChalkDict](
    redactedProcesses["17"],
  )
  assertEq(
    chalk_types.unpack[seq[string]](redactedProcess["argv"]),
    expected,
  )
  assertEq(
    chalk_types.unpack[string](fields["PODMAN_IMAGE_ID"]),
    identity,
  )
  assertEq(
    chalk_types.unpack[string](fields["DOCKER_FILE"]),
    containerfile,
  )
  assertEq(
    chalk_types.unpack[seq[string]](fields["_OP_ARGV"]),
    executionArgv,
  )

proc expectReportRedaction(
    confidential: openArray[PodmanConfidentialArg],
    command, expected: string,
) =
  expectRawReportRedaction(
    confidential,
    @["/bin/sh", "-c", command],
    @["/bin/sh", "-c", expected],
  )

proc main() =
  let nativeInlineArgs = @[
    "build",
    "--build-arg=TOKEN=public sentinel",
    "--env=TOKEN=public'\"sentinel",
    "--secret=id=token,src=/run/public\\sentinel",
    "--ssh=default=/run/public|sentinel",
    "--build-context=tools=/tmp/public;&|<>()sentinel",
    ".",
  ]
  let nativeInlineRoute = expectBuildRoute(nativeInlineArgs)
  assertEq(nativeInlineRoute.spec.confidentialArgs, @[
    PodmanConfidentialArg(
      flag: "--build-arg",
      value: "TOKEN=public sentinel",
    ),
    PodmanConfidentialArg(
      flag: "--env",
      value: "TOKEN=public'\"sentinel",
    ),
    PodmanConfidentialArg(
      flag: "--secret",
      value: "id=token,src=/run/public\\sentinel",
    ),
    PodmanConfidentialArg(
      flag: "--ssh",
      value: "default=/run/public|sentinel",
    ),
    PodmanConfidentialArg(
      flag: "--build-context",
      value: "tools=/tmp/public;&|<>()sentinel",
    ),
  ])
  let unrelatedTokens = @[
    "a", "1", "'", "\"", "\\", ";", "&", "|", "<", ">", "(", ")",
  ]
  let nativeReportArgv = @["podman"] & nativeInlineArgs & unrelatedTokens
  assertEq(
    redactPodmanArgv(
      nativeReportArgv,
      nativeInlineRoute.spec.confidentialArgs,
    ),
    @[
      "podman", "build",
      "--build-arg=" & redactedArgText,
      "--env=" & redactedArgText,
      "--secret=" & redactedArgText,
      "--ssh=" & redactedArgText,
      "--build-context=" & redactedArgText,
      ".",
    ] & unrelatedTokens,
  )
  assertEq(nativeReportArgv, @["podman"] & nativeInlineArgs & unrelatedTokens)

  let embeddedSentinel = "ci-embedded-flag-sentinel"
  let embeddedNativeArgs = @[
    "build",
    "--build-arg=TOKEN=" & embeddedSentinel,
    "--build-arg=TOKEN=" & embeddedSentinel & " value",
    ".",
  ]
  let embeddedRoute = expectBuildRoute(embeddedNativeArgs)
  assertEq(
    redactPodmanArgv(embeddedNativeArgs, embeddedRoute.spec.confidentialArgs),
    @[
      "build",
      "--build-arg=" & redactedArgText,
      "--build-arg=" & redactedArgText,
      ".",
    ],
  )
  assertEq(embeddedRoute.spec.originalArgs, embeddedNativeArgs)
  assertEq(embeddedNativeArgs, @[
    "build",
    "--build-arg=TOKEN=" & embeddedSentinel,
    "--build-arg=TOKEN=" & embeddedSentinel & " value",
    ".",
  ])

  let embeddedShellArgvs = @[
    (
      argv: @["make", "image",
              "EXTRA=--build-arg=TOKEN=" & embeddedSentinel],
      expected: @["make", "image", redactedArgText],
    ),
    (
      argv: @["/bin/sh", "-c", "podman build '--build-arg=TOKEN=" &
              embeddedSentinel & " value' ."],
      expected: @["/bin/sh", "-c", redactedArgText],
    ),
    (
      argv: @["/bin/sh", "-c", "ARGS=\"--build-arg=TOKEN=" &
              embeddedSentinel & "\"; podman build $ARGS ."],
      expected: @["/bin/sh", "-c", redactedArgText],
    ),
  ]
  for shellArgv in embeddedShellArgvs:
    expectRawReportRedaction(
      embeddedRoute.spec.confidentialArgs,
      shellArgv.argv,
      shellArgv.expected,
    )

  let valueOnlyArgvs = @[
    @[
      "make", "image", "BUILD_ARGS=TOKEN=" & embeddedSentinel,
    ],
    @[
      "/bin/sh", "-c", "echo TOKEN=" & embeddedSentinel &
        "; podman build --build-arg TOKEN=" & embeddedSentinel & " .",
    ],
    @[
      "/bin/sh", "-c", "echo TOKEN=\"" & embeddedSentinel &
        "\"; podman build --build-arg TOKEN=\"" & embeddedSentinel &
        "\" .",
    ],
  ]
  for valueOnlyArgv in valueOnlyArgvs:
    expectRawReportRedaction(
      embeddedRoute.spec.confidentialArgs,
      valueOnlyArgv,
      @[valueOnlyArgv[0], valueOnlyArgv[1], redactedArgText],
    )

  let quotedValueOnlyArgvs = @[
    @["make", "image", "TOKEN=\"" & embeddedSentinel & "\""],
    @["make", "image", "TOKEN='" & embeddedSentinel & "'"],
    @["make", "image", "TOKEN=ci-embedded-flag-\\sentinel"],
  ]
  for valueOnlyArgv in quotedValueOnlyArgvs:
    let expected = @[valueOnlyArgv[0], valueOnlyArgv[1], redactedArgText]
    expectRawReportRedaction(
      embeddedRoute.spec.confidentialArgs,
      valueOnlyArgv,
      expected,
    )
    let redacted = redactPodmanArgv(
      valueOnlyArgv,
      embeddedRoute.spec.confidentialArgs,
    )
    assertEq(redacted, expected)
    assertEq(
      redactPodmanArgv(redacted, embeddedRoute.spec.confidentialArgs),
      redacted,
    )

  let quotedOperandConfidential = @[
    PodmanConfidentialArg(
      flag: "--build-arg",
      value: "TOKEN=ci-'embedded'-flag-\\\"sentinel\"",
    ),
  ]
  expectRawReportRedaction(
    quotedOperandConfidential,
    @["make", "image", "TOKEN=ci-embedded-flag-sentinel"],
    @["make", "image", redactedArgText],
  )
  assertEq(
    redactPodmanArgv(
      @["make", "image", "unrelated"],
      @[PodmanConfidentialArg(flag: "--build-arg", value: "'\"\\")],
    ),
    @["make", "image", "unrelated"],
  )

  let sentinel = "ci-quoted-ancestor-sentinel"
  let value = sentinel & " value"
  let nativeArgs = @[
    "build", "--build-arg", "TOKEN=" & value, ".",
  ]
  let route = expectBuildRoute(nativeArgs)
  assertEq(route.spec.confidentialArgs, @[
    PodmanConfidentialArg(
      flag: "--build-arg",
      value: "TOKEN=" & value,
    ),
  ])

  let shellForms = @[
    (
      command: "podman build --build-arg TOKEN=\"" & value & "\" .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg TOKEN='" & value & "' .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg \"TOKEN=" & value & "\" .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg TOKEN=" &
        value.replace(" ", "\\ ") & " .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg " &
        "TOKEN=ci-\"quoted\"-ancestor-sentinel' value' .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg=TOKEN=\"" & value & "\" .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --build-arg TOKEN=\"" & value &
        "\"&&podman push image",
      expected: redactedArgText,
    ),
  ]
  for shellForm in shellForms:
    expectReportRedaction(
      route.spec.confidentialArgs,
      shellForm.command,
      shellForm.expected,
    )
    let redacted = redactPodmanArgv(
      @["/bin/sh", "-c", shellForm.command],
      route.spec.confidentialArgs,
    )
    assertEq(redacted, @["/bin/sh", "-c", shellForm.expected])
    assertEq(
      redactPodmanArgv(redacted, route.spec.confidentialArgs),
      redacted,
    )

  let nativeRedacted = @[
    "podman", "build", "--build-arg=" & redactedArgText, ".",
  ]
  assertEq(
    redactPodmanArgv(nativeRedacted, route.spec.confidentialArgs),
    nativeRedacted,
  )
  let markerPrefixConfidential = @[
    PodmanConfidentialArg(
      flag: "--build-arg",
      value: redactedArgText & "suffix",
    ),
  ]
  assertEq(
    redactPodmanArgv(
      @[
        "/bin/sh", "-c",
        "podman build --build-arg '" & redactedArgText & "'suffix .",
      ],
      markerPrefixConfidential,
    ),
    @["/bin/sh", "-c", redactedArgText],
  )

  let markerAssignmentConfidential = @[
    PodmanConfidentialArg(
      flag: "--build-arg",
      value: "NAME=" & redactedArgText,
    ),
  ]
  let markerAssignmentRedacted = redactPodmanArgv(
    @[
      "/bin/sh", "-c",
      "podman build --build-arg NAME=" & redactedArgText & " .",
    ],
    markerAssignmentConfidential,
  )
  assertEq(markerAssignmentRedacted, @["/bin/sh", "-c", redactedArgText])
  assertEq(
    redactPodmanArgv(
      markerAssignmentRedacted,
      markerAssignmentConfidential,
    ),
    markerAssignmentRedacted,
  )

  let nativeCollisionCases = @[
    (
      argv: @["podman", "build", "--ssh=redact", "."],
      confidential: PodmanConfidentialArg(
        flag: "--ssh",
        value: "redact",
      ),
      expected: @["podman", "build", "--ssh=" & redactedArgText, "."],
    ),
    (
      argv: @["podman", "build", "--env=env", "."],
      confidential: PodmanConfidentialArg(
        flag: "--env",
        value: "env",
      ),
      expected: @["podman", "build", "--env=" & redactedArgText, "."],
    ),
  ]
  for collision in nativeCollisionCases:
    let redacted = redactPodmanArgv(
      collision.argv,
      @[collision.confidential],
    )
    assertEq(redacted, collision.expected)
    assertEq(
      redactPodmanArgv(redacted, @[collision.confidential]),
      collision.expected,
    )

  let shellCollisionConfidential = @[
    PodmanConfidentialArg(flag: "--ssh", value: "redact"),
  ]
  let shellCollisionCases = @[
    (
      command: "podman build --ssh r'e'dact .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --ssh=r'e'dact .",
      expected: redactedArgText,
    ),
  ]
  for collision in shellCollisionCases:
    let redacted = @[
      "/bin/sh", "-c", collision.expected,
    ]
    assertEq(
      redactPodmanArgv(
        @["/bin/sh", "-c", collision.command],
        shellCollisionConfidential,
      ),
      redacted,
    )
    assertEq(
      redactPodmanArgv(redacted, shellCollisionConfidential),
      redacted,
    )

  let secretPath = "/run/ci secret"
  let secretRoute = expectBuildRoute(
    @["build", "--secret", "id=token,src=" & secretPath, "."],
  )
  let secretShellForms = @[
    (
      command: "podman build --secret id=token,src=\"" & secretPath & "\" .",
      expected: redactedArgText,
    ),
    (
      command: "podman build --secret=id=token,src='" & secretPath & "' .",
      expected: redactedArgText,
    ),
  ]
  for shellForm in secretShellForms:
    expectReportRedaction(
      secretRoute.spec.confidentialArgs,
      shellForm.command,
      shellForm.expected,
    )

  let unsupportedCommands = @[
    "podman build --build-arg TOKEN='" & value & " .",
    "podman build --build-arg TOKEN=" & sentinel & "\\",
    "podman build --build-arg TOKEN=${MISSING:-" & value & "} .",
    "podman build --build-arg TOKEN=$(printf '" & value & "') .",
    "podman build --build-arg; printf '" & value & "'",
  ]
  for command in unsupportedCommands:
    assertEq(
      redactPodmanArgv(
        @["/bin/sh", "-c", command],
        route.spec.confidentialArgs,
      ),
      @["/bin/sh", "-c", redactedArgText],
    )

  let shortPartRoute = expectBuildRoute(@[
    "build", "--build-arg", "CONTEXT=.", "--env", "DEBUG=1",
    "--secret", "id=token,src=creds", ".",
  ])
  assertEq(
    redactPodmanArgv(
      @["tool", ".", "1", "token", "creds", "CONTEXT=.", "DEBUG=1",
        "id=token,src=creds"],
      shortPartRoute.spec.confidentialArgs,
    ),
    @["tool", ".", "1", "token", "creds", redactedArgText,
      redactedArgText, redactedArgText],
  )
  assertEq(
    redactPodmanArgv(
      @["podman", "build", "--build-arg", "CONTEXT=.", "--env=DEBUG=1",
        "--secret", "id=token,src=creds", "."],
      shortPartRoute.spec.confidentialArgs,
    ),
    @["podman", "build", "--build-arg", redactedArgText,
      "--env=" & redactedArgText, "--secret", redactedArgText, "."],
  )

main()
