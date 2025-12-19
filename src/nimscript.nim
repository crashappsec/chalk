import std/[
  os,
  strutils,
]
export os
export strutils

var
  targetArch = hostCPU
  targetStr: string

proc setTargetStr(target: string) =
  targetStr = target

proc setupTargetArch(quiet = true) =
  once:
    when defined(macosx):
      # -d:arch=amd64 will allow you to specifically cross-compile to intel.
      # The .strdefine. pragma sets the variable from the -d: flag w/ the same
      # name, overriding the value of the const.
      const arch {.strdefine.} = "detect"

      var
        targetStr  = ""

      if arch == "detect":
        # On an x86 mac, the proc_translated OID doesn't exist. So if this
        # returns either 0 or 1, we know we're running on an arm. Right now,
        # nim will always use rosetta, so should always give us a '1', but
        # that might change in the future.
        let sysctlOut = staticExec("sysctl -n sysctl.proc_translated")

        if sysctlOut in ["0", "1"]:
          targetArch = "arm64"
        else:
          targetArch = "amd64"
      else:
        echo "Override: arch = " & arch

      if targetArch == "arm64":
        if not quiet:
          echo "Building for arm64"
        setTargetStr("arm64-apple-macos13")
      elif targetArch == "amd64":
        setTargetStr("x86_64-apple-macos13")
        if not quiet:
          echo "Building for amd64"
      else:
        if not quiet:
          echo "Invalid target architecture for MacOs: " & arch
        quit(1)

proc getTargetArch*(): string =
  ## The Nim compile time runs in the Javascript VM. On a Mac, for
  ## whatever crazy reason, the VM runs in an X86 emulator, meaning
  ## that Nim's `hostCPU` builtin will always report `amd64`, even when
  ## it should be reporting `arm` on M1/2/3 macs.
  ##
  ## This uses some trickery to detect when the underlying machine is
  ## `arm`. If you set -d:arch=amd64 it will override.
  ##
  ## Meant to be run from your config.nims file.
  setupTargetArch()
  return targetArch

proc getTargetStr*(): string =
  setupTargetArch()
  return targetStr

template staticLinkLibraries*(libNames: openarray[string],
                              libDir: string,
                              ) =
  ## Automates statically linking all appropriate libraries.
  ## Meant to be called from your config.nims file.
  for item in libNames:
    let libFile = "lib" & item & ".a"
    switch("passL", libDir.joinPath(libFile))
    switch("dynlibOverride", item)
