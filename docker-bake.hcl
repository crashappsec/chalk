target "chalk" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache"]
}

target "server" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
}

target "tests" {
  # comment while github sync permissions for new package
  # cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
  # cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
}
