import os, tables, streams, strutils, httpclient, net, uri, options, nimutils,
       types, lex, typecheck, errmsg

# This has some cyclic dependencies, so we make sure C prototypes get
# generated with local scope only; we then do not import those modules.

proc parse(s: seq[Con4mToken], filename: string): Con4mNode {.importc, cdecl.}
proc checkTree(node: Con4mNode, s: ConfigState) {.importc, cdecl.}

var defaultUrlStore = ""

proc fullComponentSpec*(name, location: string): string =
  var path: string
  if location == "":
    if defaultUrlStore != "":
      path = defaultUrlStore
    else:
      path = getAppDir().resolvePath()

  elif location.startsWith("https://"):
    path = location

  else:
    path = location.resolvePath()

  if path.startsWith("https://"):
    result = path & "/" & name
  else:
    result = path.joinPath(name)

proc setDefaultStoreUrl*(url: string) =
  once:
    defaultUrlStore = url

proc getComponentReference*(s: ConfigState, url: string): ComponentInfo =
  if url notin s.components:
    s.components[url] = ComponentInfo(url: url)

  return s.components[url]

proc getComponentReference*(s: ConfigState, name, loc: string): ComponentInfo =
  return s.getComponentReference(fullComponentSpec(name, loc))

proc fetchAttempt(url: string): string =
  let response = safeRequest(url = url, httpMethod = HttpGet, timeout = 1000)

  if not response.code.is2xx():
    return ""

  return response.body()

proc cacheComponent*(component: ComponentInfo, str: string, force = false) =
  if component.entrypoint != nil and not force:
    return

  component.source = str
  component.hash   = sha256(component.source)

  let (valid, toks) = component.source.lex(component.url)

  if not valid:
    let msg = case toks[^1].kind
    of ErrorTok:         "Invalid character found"
    of ErrorLongComment: "Unterminated comment"
    of ErrorStringLit:   "Unterminated string"
    of ErrorCharLit:     "Invalid char literal"
    of ErrorOtherLit:    "Unterminated literal"
    else:                "Unknown error" # Not be possible w/o a lex bug
    fatal(msg, toks[^1])

  component.entrypoint = toks.parse(component.url)

proc cacheComponent*(component: ComponentInfo, stream: Stream) =
  component.cacheComponent(stream.readAll())

proc fetchComponent*(item: ComponentInfo, extension = ".c4m", force = false) =
  let fullPath = item.url & extension
  var source: string

  if force or item.hash == "":
    if fullPath.startsWith("https://"):
      source = fullPath.fetchAttempt()

      if source == "":
        raise newException(IOError, "Could not retrieve needed source " &
          "file: " & fullPath)
    elif fullPath.startsWith("http:"):
      raise newException(IOError, "Insecure (http) loads are not allowed" &
        "(file: " & fullPath & ")")
    else:
      try:
        source = fullPath.readFile()
      except:
        raise newException(IOError, "Could not retrieve needed source " &
          "file: " & fullPath)

    item.cacheComponent(source, force)

proc fetchComponent*(s: ConfigState, name, loc: string, extension = ".c4m",
                     force = false): ComponentInfo =
  ## This returns a parsed component, but does NOT go beyond that.  The
  ## parse phase will NOT attempt to semantically validate a component,
  ## will NOT go and fetch dependent comonents, and will NOT do cycle
  ## checking at all. Use loadComponent below for those.
  ##
  ## This will raise an exception if anything goes wrong.

  result = s.getComponentReference(name, loc)

  result.fetchComponent(extension, force)

proc getUsedComponents*(component: ComponentInfo, paramOnly = false):
                      seq[ComponentInfo] =
  var
    allDependents: seq[ComponentInfo] = @[component]

  for sub in component.componentsUsed:
    if sub notin result:
      result.add(sub)
    let sublist = sub.getUsedComponents()
    for item in sublist:
      if item == component:
        raise newException(ValueError, "Cyclical components not allowed-- " &
          "component " & component.url & " can import itself")
      if item notin allDependents:
        allDependents.add(item)

  if not paramOnly:
    return allDependents
  else:
    for item in allDependents:
      if item.varParams.len() != 0 or item.attrParams.len() != 0:
        if item notin result:
          result.add(item)

proc loadComponent*(s: ConfigState, component: ComponentInfo):
                  seq[ComponentInfo] {.discardable.} =
  ## Recursively fetches any dependent components (if not cached) and
  ## checks them.

  if component.cycle:
    raise newException(ValueError, "Cyclical components are not allowed-- " &
      "component " & component.url & " can import itself")

  if component.hash == "":
    component.fetchComponent()

  let
    savedComponent = s.currentComponent
    savedPass      = s.secondPass


  if not component.typed:
    s.secondPass                  = false
    s.currentComponent            = component
    component.entryPoint.varScope = VarScope(parent: none(VarScope))

    component.entrypoint.checkTree(s)
    component.typed = true

    for subcomponent in component.componentsUsed:
      s.loadComponent(subcomponent)

    s.currentComponent = savedComponent
    s.secondPass       = savedPass

  for subcomponent in component.componentsUsed:
    component.cycle = true
    let recursiveUsedComponents = s.loadComponent(subcomponent)
    component.cycle = false
    for item in recursiveUsedComponents:
      if item notin result:
        result.add(item)

  if component in result:
    raise newException(ValueError, "Cyclical components are not allowed-- " &
      "component " & component.url & " can import itself")

proc fullUrlToParts*(url: string): (string, string, string) =
  var fullPath: string

  if url.startswith("http://"):
    raise newException(ValueError, "Only https URLs and local files accepted")
  if url.startswith("https://") or url.startswith("/"):
    fullPath = url
  else:
    if '/' in url or defaultUrlStore == "":
      fullPath = url.resolvePath()
    else:
      if defaultUrlStore.endswith("/"):
        fullPath = defaultUrlStore & url
      else:
        fullPath = defaultUrlStore & "/" & url

  result = fullPath.splitFile()

proc componentAtUrl*(s: ConfigState, url: string, force: bool): ComponentInfo =
  ## Unlike the rest of this API, this call assumes the url is either:
  ## - A full https URL or;
  ## - A local filename, either as an absolutely path or relative to cwd.
  ##
  ## Here, unlike the other functions, we look for a file extension and chop
  ## it off.

  let
    (base, module, ext) = fullUrlToParts(url)

  result = s.fetchComponent(module, base, ext, force)

  s.loadComponent(result)

proc loadComponentFromUrl*(s: ConfigState, url: string): ComponentInfo =
  return s.componentAtUrl(url, force = true)

proc haveComponentFromUrl*(s: ConfigState, url: string): Option[ComponentInfo] =
  ## Does not fetch, only returns the component if we're using it.

  let
    (base, module, ext) = fullUrlToParts(url)

  if base.joinPath(module) notin s.components:
    return none(ComponentInfo)

  let component = s.getComponentReference(module, base)


  if component.source != "":
    result = some(component)
  else:
    result = none(ComponentInfo)

  component.fetchComponent(ext, force = false)


proc loadCurrentComponent*(s: ConfigState) =
  s.loadComponent(s.currentComponent)

template setParamValue*(s:          ConfigState,
                        component:  ComponentInfo,
                        paramName:  string,
                        value:      Box,
                        valueType:  Con4mType,
                        paramStore: untyped) =
  discard s.loadComponent(component)

  if paramName notin component.paramStore:
    raise newException(ValueError, "Parameter not found: " & paramName)

  let parameter = component.paramStore[paramName]

  if valueType.unify(parameter.defaultType).isBottom():
    raise newException(ValueError, "Incompatable type for: " & paramName)

  parameter.value = some(value)

proc setVariableParamValue*(s:         ConfigState,
                            component: ComponentInfo,
                            paramName: string,
                            value:     Box,
                            valueType: Con4mType) =
  s.setParamValue(component, paramName, value, valueType, varParams)


proc setAttributeParamValue*(s:         ConfigState,
                             component: ComponentInfo,
                             paramName: string,
                             value:     Box,
                             valueType: Con4mType) =
  s.setParamValue(component, paramName, value, valueType, attrParams)

proc setVariableParamValue*(s:         ConfigState,
                            urlKey:    string,
                            paramName: string,
                            value:     Box,
                            valueType: Con4mType) =
  let component = s.getComponentReference(urlKey)
  s.setParamValue(component, paramName, value, valueType, varParams)

proc setAttributeParamValue*(s:         ConfigState,
                             urlKey:    string,
                             paramName: string,
                             value:     Box,
                             valueType: Con4mType) =
  let component = s.getComponentReference(urlKey)
  s.setParamValue(component, paramName, value, valueType, attrParams)

proc setVariableParamValue*(s:             ConfigState,
                            componentName: string,
                            location:      string,
                            paramName:     string,
                            value:         Box,
                            valueType:     Con4mType) =
  let component = s.getComponentReference(componentName, location)
  s.setParamValue(component, paramName, value, valueType, varParams)

proc setAttributeParamValue*(s:             ConfigState,
                             componentName: string,
                             location:      string,
                             paramName:     string,
                             value:         Box,
                             valueType:     Con4mType) =
  let component = s.getComponentReference(componentName, location)
  s.setParamValue(component, paramName, value, valueType, attrParams)

proc getAllVariableParamInfo*(s:              ConfigState,
                              name, location: string): seq[ParameterInfo] =
  let component = s.getComponentReference(name, location)

  for _, v in component.varParams:
    result.add(v)

proc getAllAttrParamInfo*(s:              ConfigState,
                          name, location: string): seq[ParameterInfo] =
  let component = s.getComponentReference(name, location)

  for _, v in component.attrParams:
    result.add(v)
