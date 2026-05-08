##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  auth,
  chalkjson,
  types,
  utils/http,
  utils/json,
  utils/uri,
]
import "."/[
  exe,
]

proc loginToRegistries*() =
  for registryName in getChalkSubsections("docker.docker_registry"):
    let
      registrySection = "docker.docker_registry." & registryName
      registryUri     = attrGet[string](registrySection & ".uri").removeSuffix('/')
      loginMethod     = attrGet[string](registrySection & ".login_method")
    case loginMethod
    of "":
      continue
    of "get":
      let loginSection = registrySection & ".docker_login_get"
      if not sectionExists(loginSection):
        error("docker: login method is referencing non-existing configuration " & loginSection)
        continue
      let
        loginBase = parseUri(attrGet[string](loginSection & ".uri"))
        loginUri  = loginBase.withQueryPair("registry", registryUri)
        timeout   = cast[int](attrGet[Con4mDuration](loginSection & ".timeout"))
        authName  = attrGet[string](loginSection & ".auth")
        authOpt   = getAuthConfigByName(authName)
      var headers = newHttpHeaders()
      if authOpt.isSome():
        let auth  = authOpt.get()
        headers   = auth.implementation.injectHeaders(auth, headers)
      try:
        let
          response = safeRequest(
            url               = loginUri,
            httpMethod        = HttpGet,
            timeout           = timeout,
            headers           = headers,
            retries           = 2,
            firstRetryDelayMs = 100,
          )
          parsed   = parseJson(response.body()).assertIs(JObject)
          username = parsed{"username"}.getStr()
          password = parsed{"password"}.getStr()
          registry = parsed{"registry"}.getStr(registryUri)
          repo     = parsed{"repository"}.getStr(registry)
          args     = @[
            "login",
            "-u", username,
            "--password-stdin",
            # login by the repo just in case there the repo has diff creds
            # e.g. multiple ECR repos and each has diff auth requirements
            # although docker in many cases normalizes out the repository path
            # and just logs in to the overall registry
            repo,
          ]
        trace("docker: login get url: " & $loginUri)
        trace("docker: login get status code: " & response.status)
        trace("docker " & args.join(" "))
        discard runDockerGetEverything(args, stdin = password)
      except:
        error("docker: could not docker login to registry - " & getCurrentExceptionMsg())
