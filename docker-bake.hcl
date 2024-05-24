variable "PLATFORM" {
  default = replace(BAKE_LOCAL_PLATFORM, "/", "-")
}

target "chalk" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache-${PLATFORM}"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache-${PLATFORM}"]
}

target "server" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
}

target "tests" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
}
