import osproc, config, util

var
  dockerExeLocation: string = ""
  buildXVersion:     float  = 0   # Major and minor only


var dockerPathOpt: Option[string] = none(string)


proc setDockerExeLocation*() =
  once:
    trace("Searching path for 'docker'")
    var
      userPath: seq[string]
      exeOpt   = chalkConfig.getDockerExe()

    if exeOpt.isSome():
      userPath.add(exeOpt.get())

    dockerPathOpt     = findExePath("docker", userPath, ignoreChalkExes = true)
    dockerExeLocation = dockerPathOpt.get("")

    if dockerExeLocation == "":
       warn("No docker command found in path. `chalk docker` not available.")

proc getBuildXVersion*(): float =
  # Have to parse the thing to get compares right.
  once:
    if getEnv("DOCKER_BUILDKIT") == "0":
      return 0
    let (output, exitcode) = execCmdEx(dockerExeLocation & " buildx version")
    if exitcode == 0:
      let parts = output.split(' ')
      if len(parts) >= 2 and len(parts[1]) > 1 and parts[1][0] == 'v':
        let vparts = parts[1][1 .. ^1].split('.')
        if len(vparts) > 1:
          let majorMinorStr = vparts[0] & "." & vparts[1]
          try:
            buildXVersion = parseFloat(majorMinorStr)
          except:
            dumpExOnDebug()

  return buildXVersion

template haveBuildContextFlag*(): bool =
  buildXVersion >= 0.8

proc runDocker*(args: seq[string]): int {.discardable.} =
  trace("Running: " & dockerExeLocation & " " & args.join(" "))
  let
    subp = startProcess(dockerExeLocation,
                        args = args,
                        options = {poParentStreams})

  result = subp.waitForExit()

  subp.close()

  if result != 0:
    trace("Docker exited with code: " & $(result))

{.emit: """
#include <unistd.h>

int c_replace_stdin_with_pipe() {
  int filedes[2];

  pipe(filedes);
  dup2(filedes, 0);
  return filedes[1];
}

int c_write_to_pipe(int fd, char *s, int len) {
  return write(fd, s, len);
}
""".}

proc cReplaceStdinWithPipe(): cint {.importc: "c_replace_stdin_with_pipe".}
proc cWriteToPipe(fd: cint, s: cstring, l: cint):
                 cint {.importc: "c_write_to_pipe".}

proc runWrappedDocker*(args: seq[string], df: string): int {.discardable.} =
  trace("Running docker w/ stdin dockerfile by calling: " & dockerExeLocation &
    " " & args.join(" "))

  let
    fd   = cReplaceStdinWithPipe()
    subp = startProcess(dockerExeLocation,
                        args = args,
                        options = {poParentStreams})

  discard cWriteToPipe(fd, cstring(df), cint(len(df) + 1))
  let code = subp.waitForExit()
  subp.close()
  if code != 0:
    trace("Docker exited with code: " & $(code))

  result = int(code)

template runWrappedDocker*(info: DockerInvocation): int =
  let r = runDocker(info.newCmdLine)
  if r != 0:
    error("Wrapped docker call failed; reverting to original docker cmd")
    raise newException(ValueError, "doh")
  r

proc runDockerGetOutput*(args: seq[string]): string =
  trace("Running: " & dockerExeLocation & " " & args.join(" "))
  return execProcess(dockerExeLocation, args = args, options = {})

template extractDockerHash*(s: string): string =
  s.split(":")[1].toLowerAscii()

var contextCounter = 0

proc makeFileAvailableToDocker*(ctx:      DockerInvocation,
                                loc:      string,
                                move:     bool,
                                newName = "") =
  let (dir, file) = loc.splitPath()

  if haveBuildContextFlag():
    once:
      trace("Docker injection method: --build-context")

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add("chalktmpdir" & $(contextCounter) & "=\"" & dir & "\"")
    ctx.addedInstructions.add("COPY --from=chalkexedir" & $(contextCounter) &
      " " & file & " /" & newname)
    contextCounter += 1
    if move:
      ctx.tmpFiles.add(loc)
  elif ctx.foundContext == "-":
    warn("Cannot chalk when context is passed to stdin w/o BUILDKIT support")
    raise newException(ValueError, "stdinctx")
  else:
    let
      contextDir  = resolvePath(ctx.foundContext)
      dstLoc      = contextDir.joinPath(file)

    if not dirExists(contextDir):
      warn("Cannot find context directory (" & contextDir &
        "), so cannot wrap entry point.")
      raise newException(ValueError, "ctxwrite")
    if fileExists(dstLoc):
      # This shouldn't happen w/ the chalk mark, as the file name is randomized
      # but it could happen w/ the chalk exe
      warn("File name: '" & file & "already exists in the context. Assuming " &
        "this is the file to copy in.")
      return
    else:
      try:
        if move:
          moveFile(loc, dstLoc)
        else:
          copyFile(loc, dstLoc)

        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
        ctx.tmpFiles.add(dstLoc)
      except:
        dumpExOnDebug()
        warn("Could not write to context directory.")
        raise newException(ValueError, "ctxcpy")

proc chooseNewTag*(): string =
  let
    randInt = secureRand[uint]()
    hexVal  = toHex(randInt and 0xffffffffffff'u).toLowerAscii()

  return "chalk-" & hexVal & ":latest"

proc getAllDockerContexts*(info: DockerInvocation): seq[string] =
  if info.foundContext != "" and info.foundContext != "-":
    result.add(resolvePath(info.foundContext))

  for k, v in info.otherContexts:
    result.add(resolvePath(v))
