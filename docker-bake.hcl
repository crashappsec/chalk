target "chalk" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache"]
}

target "server" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
}

target "tests" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
}
