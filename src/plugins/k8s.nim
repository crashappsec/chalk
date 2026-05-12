##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  net,
  os,
]
import ".."/[
  chalkjson,
  normalize,
  plugin_api,
  run_management,
  types,
  utils/envvars,
  utils/files,
  utils/http,
  utils/json,
  utils/strings,
]

proc getContainerInfo(
  podManifest:   JsonNode,
  clusterId:     string,
  namespace:     string,
  containerName: string,
): ChalkDict =
  result = ChalkDict()
  var container: JsonNode
  let
    spec       = podManifest{"spec"}.assertIs(JObject)
    containers = spec{"containers"}.assertIs(JArray)
    volumes    = spec{"volumes"}.assertIs(JArray)
  for i in containers:
    i.assertIs(JObject)
    if i{"name"}.getStr() == containerName:
      container = i
      break
  if container == nil:
    trace("k8s: could not find self container in the k8s pod containers spec")
    return

  let
    env                 = container{"env"}.assertIs(JArray)
    volumeMounts        = container{"volumeMounts"}.assertIs(JArray)
    ports               = container{"ports"}.assertIs(JArray)
    ignoredEnvVars      = attrGet[seq[string]]("exec.exec_deployment.ignored_env_vars")
    ignoredVolumeMounts = attrGet[seq[string]]("exec.exec_deployment.ignored_volume_mounts")
    downwardEnvVars     = newTable[string, string]()
    envVarHashes        = newTable[string, string]()
    volumeMountHashes   = newTable[string, string]()
    volumesByName       = newTable[string, JsonNode]()
  var
    containerPorts      = newSeq[string]()

  # note: envFrom (bulk configMap/secret imports) does not need to be handled
  # here because the chalk operator normalizes envFrom entries into individual
  # env vars in the env block before chalk sees the pod spec.
  #
  # in k8s downstream env vars are inherently unpredictable as they can
  # reference epheral things like node ip, etc.
  # Due to that chalk should ignore their values in the deployment id
  # calculation however in k8s its possible to templetiize env vars where one
  # env var fills in another env var (e.g. `DESTINATION: $(IP):8080`).
  # That means that substrings of templetized env are also unpredictable
  # but parts of them are. To account for that chalk needs to first gather
  # all downward api env var values and then detect if their values are present
  # in other env vars. If so they should be replaced with a placeholder
  # which allows other vars other bits to be correctly counted in the
  # deployment calculation making it more robust.
  #
  # First pass: collect downward API env var values so we can detect their
  # presence in templated vars in the second pass.
  # containers:
  #   - env:
  #     - name: NODE_IP
  #       valueFrom:
  #         fieldRef:
  #           fieldPath: status.hostIP
  #     - name: DESTINATION
  #       value: "$(NODE_IP):8080"
  for i in env:
    i.assertIs(JObject)
    let
      name      = i{"name"}.assertIs(JString).getStr()
      valueFrom = i{"valueFrom"}.default(newJObject()).assertIs(JObject)
      fieldRef  = valueFrom{"fieldRef"}
    if fieldRef != nil:
      let value = getEnv(name)
      if value != "":
        downwardEnvVars[name] = value
  # Second pass: hash env var values, skipping downward API vars and replacing
  # any embedded downward API values with their template placeholder.
  # containers:
  #   - env:
  #     - name: NODE_IP
  #       valueFrom:
  #         fieldRef:
  #           fieldPath: status.hostIP
  #     - name: APP_ENV
  #       value: "production"
  #     - name: DESTINATION
  #       value: "$(NODE_IP):8080"
  for i in env:
    i.assertIs(JObject)
    let
      name      = i{"name"}.assertIs(JString).getStr()
      valueFrom = i{"valueFrom"}.default(newJObject()).assertIs(JObject)
      fieldRef  = valueFrom{"fieldRef"}
    if fieldRef != nil:
      trace("k8s: ignoring env['" & name & "'] as its populated from k8s downward API making it inherently undeterministic")
      continue
    if name in ignoredEnvVars:
      trace("k8s: ignoring env['" & name & "'] as it is configured to be excluded from the deployment id")
      continue
    var value = getEnv(name)
    for k, v in downwardEnvVars:
      if v in value:
        value = value.replace(v, "$(" & k & ")")
    envVarHashes[name] = value.sha256Hex()
  result.setIfNeeded("_K8S_CONTAINER_ENV_VAR_HASHES", envVarHashes)

  # Build a lookup from volume name -> volume spec so we can resolve each mount
  for vol in volumes:
    vol.assertIs(JObject)
    volumesByName[vol{"name"}.assertIs(JString).getStr()] = vol

  # Collect file-content hashes for every configMap / secret volume mount.
  # Downward API and projected volumes (service-account tokens, pod/node fields,
  # etc.) are skipped because their content is ephemeral, just like downward API
  # env vars above.
  for i in volumeMounts:
    i.assertIs(JObject)
    let
      volName   = i{"name"}.assertIs(JString).getStr()
      mountPath = i{"mountPath"}.assertIs(JString).getStr()
      subPath   = i{"subPath"}.default(newJString("")).getStr()
      vol       = volumesByName.getOrDefault(volName)
    if vol == nil:
      trace("k8s: volumeMount references unknown volume '" & volName & "', skipping")
      continue
    if mountPath in ignoredVolumeMounts:
      trace("k8s: ignoring volumeMount at '" & mountPath & "' as it is configured to be excluded from the deployment id")
      continue
    var skippable = false
    for i in ["downwardAPI", "projected"]:
      if vol{i} != nil:
        trace("k8s: ignoring volumeMount at '" & mountPath & "' as it is from a " & i)
        skippable = true
        break
    if skippable:
      continue
    # currently we only support config maps and secrets
    let
      node =
        if "configMap" in vol:
          vol["configMap"].assertIs(JObject)
        elif "secret" in vol:
          vol["secret"].assertIs(JObject)
        else:
          continue
      items = node{"items"}
    if subPath != "":
      # Individual key from a configMap/secret mounted as a single file.
      # The file lives directly at mountPath.
      # volumes:
      #   - name: my-config
      #     configMap:
      #       name: my-configmap
      # containers:
      #   - volumeMounts:
      #     - name: my-config
      #       mountPath: /etc/config/my-key
      #       subPath: my-key
      try:
        volumeMountHashes[mountPath] = newFileStringStream(mountPath).sha256Hex()
      except:
        trace("k8s: cant hash " & mountPath & " - " & getCurrentExceptionMsg())
        dumpExOnDebug()
    elif items != nil:
      # Specific keys selected via items[]; each key is projected to a file at
      # mountPath/<item.path>.
      # volumes:
      #   - name: my-config
      #     configMap:
      #       name: my-configmap
      #       items:
      #         - key: my-key
      #           path: my-key.conf
      # containers:
      #   - volumeMounts:
      #     - name: my-config
      #       mountPath: /etc/config
      for item in items.assertIs(JArray):
        item.assertIs(JObject)
        let path = mountPath / item{"path"}.assertIs(JString).getStr()
        try:
          volumeMountHashes[path] = newFileStringStream(path).sha256Hex()
        except:
          trace("k8s: cant hash " & path & " - " & getCurrentExceptionMsg())
          dumpExOnDebug()
    else:
      # Full mount — every key in the configMap/secret becomes a file under
      # mountPath, so walk the directory and hash each file.
      # volumes:
      #   - name: my-config
      #     configMap:
      #       name: my-configmap
      # containers:
      #   - volumeMounts:
      #     - name: my-config
      #       mountPath: /etc/config
      for kind, path in walkDir(mountPath):
        if kind == pcFile:
          try:
            volumeMountHashes[path] = newFileStringStream(path).sha256Hex()
          except:
            trace("k8s: cant hash " & path & " - " & getCurrentExceptionMsg())
            dumpExOnDebug()
  result.setIfNeeded("_K8S_CONTAINER_VOLUME_MOUNT_HASHES", volumeMountHashes)

  # Collect all declared container ports as a list of "<port>/<protocol>"
  # entries, following the standard unix /etc/services convention.
  # protocol defaults to TCP when omitted.
  # containers:
  #   - ports:
  #     - name: http
  #       containerPort: 8080
  #       protocol: TCP
  for i in ports:
    i.assertIs(JObject)
    let
      containerPort = i{"containerPort"}.assertIs(JInt).getInt()
      protocol      = i{"protocol"}.getStr().elseWhenEmpty("TCP")
    containerPorts.add($containerPort & "/" & protocol)
  result.setIfNeeded("_K8S_CONTAINER_PORTS", containerPorts)

  if getBaseCommandName() != "exec":
    return
  if (
    execChalk == nil or
    not execChalk.isChalked() or
    "METADATA_ID" notin execChalk.extract
  ):
    trace("k8s: cant compute deployment id - exec doesnt have a chalkmark with METADATA_ID")
    return
  let input = %*({
    "METADATA_ID":    unpack[string](execChalk.extract["METADATA_ID"]),
    "clusterId":      clusterId,
    "namespace":      namespace,
    "containerName":  containerName,
    "argv":           getArgs(),
    "ports":          containerPorts,
    "envVars":        envVarHashes,
    "volumeMounts":   volumeMountHashes,
  })
  result.setIfNeeded("_EXEC_DEPLOYMENT_ID", input.nimJsonToBox().binEncodeItem().sha256Hex())

proc k8sGetRunTimeHostInfo*(self: Plugin,
                            objs: seq[ChalkObj],
                            ): ChalkDict {.cdecl.} =
  result = ChalkDict()

  let
    rawK8sMetadata = getEnv("CHALK_K8S_METADATA")
    namespace      = getEnv("CHALK_K8S_POD_NAMESPACE")
    podName        = getEnv("CHALK_K8S_POD_NAME")
    containerName  = getEnv("CHALK_K8S_POD_CONTAINER_NAME")
  if rawK8sMetadata == "" or namespace == "" or podName == "":
    return

  result.setIfNeeded("_K8S_POD_NAME", podName)
  var clusterId = ""
  try:
    let
      k8sMetadata     = parseJson(rawK8sMetadata).assertIs(JObject)
      clusterMetadata = k8sMetadata{"cluster"}.assertIs(JObject)
    clusterId = clusterMetadata{"uid"}.getStr()
    result.setIfNeeded("_K8S_CLUSTER_ID",         clusterId)
    result.setIfNeeded("_K8S_CLUSTER_NAME",       clusterMetadata{"name"}.getStr())
    result.setIfNeeded("_K8S_CLUSTER_ENDPOINT",   clusterMetadata{"endpoint"}.getStr())
    result.setIfNeeded("_K8S_POD_NAMESPACE",      namespace)
    result.setIfNeeded("_K8S_POD_CONTAINER_NAME", containerName)
  except:
    trace("k8s: could not parse cluster metadata: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return

  let
    podMetadataUrl       = getEnv("CHALK_K8S_PODINFO_URL")
    podMetadataTokenPath = getEnv("CHALK_K8S_PODINFO_TOKEN_PATH")
  if podMetadataUrl == "" or containerName == "" or podMetadataTokenPath == "":
    return
  let token = tryToLoadFile(podMetadataTokenPath)
  if token == "":
    return
  let podInfoUrl = podMetadataUrl & "/v1/podinfo/" & namespace & "/" & podName
  trace("k8s: fetching pod manifest from " & podInfoUrl)
  var podManifest: JsonNode
  try:
    let response = safeRequest(
      url               = podInfoUrl,
      retries           = 2,
      firstRetryDelayMs = 100,
      acceptStatusCodes = @[200..200],
      headers           = newHttpHeaders(@[
        ("Authorization", "Bearer " & token)
      ]),
    )
    podManifest          = parseJson(response.body()).assertIs(JObject)
    let metadata         = podManifest{"metadata"}.assertIs(JObject)
    result.trySetIfNeeded("_K8S_POD_MANIFEST",    podManifest.nimJsonToBox())
    result.trySetIfNeeded("_K8S_POD_LABELS",      metadata{"labels"}.default(newJObject()).assertIs(JObject).nimJsonToBox())
    result.trySetIfNeeded("_K8S_POD_ANNOTATIONS", metadata{"annotations"}.default(newJObject()).assertIs(JObject).nimJsonToBox())
  except:
    trace("k8s: could not fetch pod manifest: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return

  try:
    result.update(getContainerInfo(
      podManifest   = podManifest,
      clusterId     = clusterId,
      namespace     = namespace,
      containerName = containerName,
    ))
  except:
    trace("k8s: could not collect container info: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return

proc loadK8s*() =
  newPlugin("k8s",
            rtHostCallback = RunTimeHostCb(k8sGetRunTimeHostInfo))
