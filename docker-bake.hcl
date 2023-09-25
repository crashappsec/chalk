variable "VERSION" {
  default = "latest"
}

target "chalk" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_compile:cache"]
}

target "server" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
}

target "server-release" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_local_api_server:cache"]
  platforms  = ["linux/amd64", "linux/arm64"]
  tags = [
    "ghcr.io/crashappsec/chalk-test-server:${VERSION}",
    "ghcr.io/crashappsec/chalk-test-server:latest",
  ]
}

target "tests" {
  cache-from = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
  cache-to   = ["type=registry,ref=ghcr.io/crashappsec/chalk_tests:cache"]
}
