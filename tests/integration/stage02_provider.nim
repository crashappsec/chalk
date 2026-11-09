import std/[os, json]
import ../../src/[commands, config, confload, sinks, types]
import ../../src/attestation/[get, utils]

ioSetup()
loadAllConfigs()
echo "STAGE02_SOURCE " & getChalkCommitId()

if getEnv("STAGE02_OPERATION") == "mint":
  let key = mintAttestationKeyToDisk(getEnv("STAGE02_KEY_PATH"))
  writeFile(getEnv("STAGE02_FIXTURE"), $(%*{
    "privateKey": key.privateKey,
    "publicKey": key.publicKey,
    "password": key.password,
  }))
else:
  let provider = AttestationKeyProvider(getProvider)
  try:
    provider.init(provider)
    if getEnv("STAGE02_OPERATION") == "password":
      let password = provider.retrievePassword(provider, AttestationKey())
      doAssert password == getEnv("STAGE02_EXPECT_PASSWORD")
      echo "STAGE02_PASSWORD_VERIFIED"
    else:
      let key = provider.retrieveKey(provider)
      let message = "stage 2 synthetic signing regression"
      let signature = key.sign(message)
      doAssert key.verify(message, signature)
      doAssert not key.verify(message & " changed", signature)
      echo "STAGE02_SIGNING_VERIFIED"
  except:
    echo "STAGE02_FAILURE: " & getCurrentExceptionMsg()
    quit(1)
