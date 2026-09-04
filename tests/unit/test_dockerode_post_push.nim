import std/[
  json,
  os,
  posix,
  strutils,
  tempfiles,
]
import ../../src/docker/exe
import ../../src/dockerode_post_push/payload

proc main() =
  let
    baseAuth = %*{
      "auths": {
        "ambient.example": {"auth": "ambient"},
        "sdk.example": {"auth": "old"},
      },
      "credsStore": "desktop",
    }
    overlayAuth = %*{"auths": {"sdk.example": {"auth": "sdk"}}}
    mergedAuth = mergeDockerAuthConfig(baseAuth, overlayAuth)

  doAssert mergeDockerAuthConfig(baseAuth, newJObject()) == baseAuth
  doAssert mergedAuth{"credsStore"}.getStr() == "desktop"
  doAssert mergedAuth{"auths"}{"ambient.example"}{"auth"}.getStr() == "ambient"
  doAssert mergedAuth{"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"
  mergedAuth["auths"]["sdk.example"]["auth"] = %"changed"
  doAssert baseAuth{"auths"}{"sdk.example"}{"auth"}.getStr() == "old"
  doAssert overlayAuth{"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"
  setDockerAuthConfigOverlay(overlayAuth)
  doAssert getDockerAuthConfig(){"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"
  resetDockerAuthConfig()
  doAssert getDockerAuthConfig(){"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"

  doAssert not dockerPostPushSocketSupported(
    "/tmp/chalk-dockerode-home/.docker/run/docker.sock",
  )

  let payloadFixture = createTempFile("chalk-dockerode-payload-", ".json")
  try:
    payloadFixture.cfile.write('x'.repeat(dockerPostPushMaxPayloadBytes + 1))
    payloadFixture.cfile.setFilePos(0)
    doAssert readDockerPostPushPayload(payloadFixture.cfile).len ==
      dockerPostPushMaxPayloadBytes + 1
  finally:
    payloadFixture.cfile.close()
    removeFile(payloadFixture.path)

main()
