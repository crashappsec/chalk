proc n00bInit(
  argc: cint,
  argv: pointer,
  envp: pointer,
) {.importc:"n00b_init".}

proc n00bInstallDefaultStyles() {.importc:"n00b_install_default_styles".}

proc setupN00b*() =
  let argv = @[cstring("chalk"), cast[cstring](nil)]
  let envp = @[cast[cstring](nil)]
  n00bInit(
    1,
    addr(argv[0]),
    addr(envp[0]),
  )
  n00bInstallDefaultStyles()
