import std/uri
import ../../src/types
import ../../src/docker/ids

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc image(a, b, c: string): DockerImage =
  return (a, b, c)

proc main() =
  assertEq(parseImage("foo"), image("foo", "latest", ""))
  assertEq(parseImage("foo/bar"), image("foo/bar", "latest", ""))
  assertEq(parseImage("foo:tag"), image("foo", "tag", ""))
  assertEq(parseImage("foo/bar:tag"), image("foo/bar", "tag", ""))
  assertEq(parseImage("foo@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"), image("foo", "latest", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"))
  assertEq(parseImage("foo/bar@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"), image("foo/bar", "latest", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"))
  assertEq(parseImage("foo:tag@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"), image("foo", "tag", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"))
  assertEq(parseImage("foo/bar:tag@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"), image("foo/bar", "tag", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"))
  assertEq(parseImage("foo.com/test"), image("foo.com/test", "latest", ""))
  assertEq(parseImage("foo.com/test:tag"), image("foo.com/test", "tag", ""))
  assertEq(parseImage("foo.com:1234/test"), image("foo.com:1234/test", "latest", ""))
  assertEq(parseImage("foo.com:1234/test:tag"), image("foo.com:1234/test", "tag", ""))
  assertEq(parseImage("127.0.0.1/test:tag"), image("127.0.0.1/test", "tag", ""))
  assertEq(parseImage("127.0.0.1:1234/test:tag"), image("127.0.0.1:1234/test", "tag", ""))
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]/test"), image("[2001:df8:0:0:0:ab1:0:0]/test", "latest", ""))
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]/test:tag"), image("[2001:df8:0:0:0:ab1:0:0]/test", "tag", ""))
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]:1234/test:tag"), image("[2001:df8:0:0:0:ab1:0:0]:1234/test", "tag", ""))

  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]/test:tag").registry, "[2001:df8:0:0:0:ab1:0:0]")
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]/test:tag").domain, "[2001:df8:0:0:0:ab1:0:0]")
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]:1234/test:tag").registry, "[2001:df8:0:0:0:ab1:0:0]:1234")
  assertEq(parseImage("[2001:df8:0:0:0:ab1:0:0]:1234/test:tag").domain, "[2001:df8:0:0:0:ab1:0:0]")

  assertEq(parseImage("sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"), image("", "", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"))

  assertEq($(parseImage("foo").uri), "https://registry-1.docker.io/v2/library/foo")
  assertEq($(parseImage("docker.io/foo").uri), "https://registry-1.docker.io/v2/library/foo")
  assertEq($(parseImage("index.docker.io/foo").uri), "https://registry-1.docker.io/v2/library/foo")
  assertEq($(parseImage("registry-1.docker.io/foo").uri), "https://registry-1.docker.io/v2/library/foo")
  assertEq($(parseImage("foo/bar").uri), "https://registry-1.docker.io/v2/foo/bar")
  assertEq($(parseImage("docker.io/foo/bar").uri), "https://registry-1.docker.io/v2/foo/bar")
  assertEq($(parseImage("index.docker.io/foo/bar").uri), "https://registry-1.docker.io/v2/foo/bar")
  assertEq($(parseImage("registry-1.docker.io/foo/bar").uri), "https://registry-1.docker.io/v2/foo/bar")
  assertEq($(parseImage("Foo/bar").uri), "https://Foo/v2/bar")
  assertEq($(parseImage("foo.com/bar").uri), "https://foo.com/v2/bar")
  assertEq($(parseImage("foo:1234/bar").uri), "https://foo:1234/v2/bar")
  assertEq($(parseImage("localhost/bar").uri), "http://localhost/v2/bar")
  assertEq($(parseImage("localhost:1234/bar").uri), "http://localhost:1234/v2/bar")
  assertEq($(parseImage("127.0.0.1/bar").uri), "http://127.0.0.1/v2/bar")
  assertEq($(parseImage("127.0.0.1:1234/bar").uri), "http://127.0.0.1:1234/v2/bar")
  assertEq($(parseImage("1.1.1.1/bar").uri), "https://1.1.1.1/v2/bar")
  assertEq($(parseImage("1.1.1.1:1234/bar").uri), "https://1.1.1.1:1234/v2/bar")
  assertEq($(parseImage("[2001:df8:0:0:0:ab1:0:0]/bar").uri), "https://[2001:df8:0:0:0:ab1:0:0]/v2/bar")
  assertEq($(parseImage("[2001:df8:0:0:0:ab1:0:0]:1234/bar").uri), "https://[2001:df8:0:0:0:ab1:0:0]:1234/v2/bar")

  assertEq($(parseImage("localhost/bar").uri(scheme="https://")), "https://localhost/v2/bar")
  assertEq($(parseImage("foo").uri(path = "/manifests/latest")), "https://registry-1.docker.io/v2/library/foo/manifests/latest")
  assertEq($(parseImage("foo").uri(prefix = "/bar")), "https://registry-1.docker.io/bar/v2/library/foo")
  assertEq($(parseImage("foo").uri(project = "/bar")), "https://registry-1.docker.io/v2/bar/library/foo")

  assertEq($(parseImage("foo").withRegistry("foo.com").uri), "https://foo.com/v2/library/foo")
  assertEq($(parseImage("foo").withRegistry("foo.com:1234").uri), "https://foo.com:1234/v2/library/foo")
  assertEq($(parseImage("example.com/foo").withRegistry("foo.com").uri), "https://foo.com/v2/foo")
  assertEq($(parseImage("example.com:1234/foo").withRegistry("foo.com").uri), "https://foo.com/v2/foo")
  assertEq($(parseImage("example.com/foo").withRegistry("foo.com:1234").uri), "https://foo.com:1234/v2/foo")
  assertEq($(parseImage("example.com:4567/foo").withRegistry("foo.com:1234").uri), "https://foo.com:1234/v2/foo")

main()
