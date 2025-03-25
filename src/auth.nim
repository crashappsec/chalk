##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "."/config

var availableAuthConfigs: Table[string, AuthConfig]

proc getAuthConfigByName*(name: string,
                          attr: AttrScope = AttrScope(nil),
                          ): Option[AuthConfig] =
  if name == "":
    return none(AuthConfig)

  if name in availableAuthConfigs:
    return some(availableAuthConfigs[name])

  let
    attrRoot = if attr != nil: attr else: getChalkScope()
    section  = "auth_config." & name
    opts     = OrderedTableRef[string, string]()

  if attrRoot.getObjectOpt(section).isNone():
    error(section & " is referenced but its missing in the config")
    return none(AuthConfig)

  let authType = getOpt[string](attrRoot, section & ".auth").getOrElse("")
  if authType == "":
    error(section & ".auth is required")
    return none(AuthConfig)

  let implementationOpt = getAuthImplementation(authType)
  if implementationOpt.isNone():
    error("there is no implementation for " & authType & " auth")
    return none(AuthConfig)

  for k, _ in getObject(attrRoot, section).contents:
    case k
    of "auth":
      continue
    else:
      let boxOpt = getOpt[Box](attrRoot, section & "." & k)
      if boxOpt.isSome():
        opts[k]  = unpack[string](boxOpt.get())
      else:
        error(section & "." & k & " is missing")
        return none(AuthConfig)

  try:
    result = configAuth(implementationOpt.get(), name, some(opts))
  except:
    error(section & " is misconfigured: " & getCurrentExceptionMsg())
    return none(AuthConfig)

  if result.isSome():
    availableAuthConfigs[name] = result.get()
