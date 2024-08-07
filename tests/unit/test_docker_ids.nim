import std/uri
import ../../src/docker/ids

proc main() =
  doAssert parseImage("foo") == ("foo", "latest", "")
  doAssert parseImage("foo/bar") == ("foo/bar", "latest", "")
  doAssert parseImage("foo:tag") == ("foo", "tag", "")
  doAssert parseImage("foo/bar:tag") == ("foo/bar", "tag", "")
  doAssert parseImage("foo@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630") == ("foo", "latest", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630")
  doAssert parseImage("foo/bar@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630") == ("foo/bar", "latest", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630")
  doAssert parseImage("foo:tag@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630") == ("foo", "tag", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630")
  doAssert parseImage("foo/bar:tag@sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630") == ("foo/bar", "tag", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630")
  doAssert parseImage("foo.com/test") == ("foo.com/test", "latest", "")
  doAssert parseImage("foo.com/test:tag") == ("foo.com/test", "tag", "")
  doAssert parseImage("foo.com:1234/test") == ("foo.com:1234/test", "latest", "")
  doAssert parseImage("foo.com:1234/test:tag") == ("foo.com:1234/test", "tag", "")
  doAssert parseImage("127.0.0.1/test:tag") == ("127.0.0.1/test", "tag", "")
  doAssert parseImage("127.0.0.1:1234/test:tag") == ("127.0.0.1:1234/test", "tag", "")
  doAssert parseImage("sha256:bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630") == ("", "", "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630")

  doAssert $(parseImage("foo").uri) == "https://registry-1.docker.io/v2/library/foo"
  doAssert $(parseImage("foo/bar").uri) == "https://registry-1.docker.io/v2/foo/bar"
  doAssert $(parseImage("Foo/bar").uri) == "https://Foo/v2/bar"
  doAssert $(parseImage("foo.com/bar").uri) == "https://foo.com/v2/bar"
  doAssert $(parseImage("foo:1234/bar").uri) == "https://foo:1234/v2/bar"
  doAssert $(parseImage("localhost/bar").uri) == "http://localhost/v2/bar"
  doAssert $(parseImage("localhost:1234/bar").uri) == "http://localhost:1234/v2/bar"
  doAssert $(parseImage("127.0.0.1/bar").uri) == "http://127.0.0.1/v2/bar"
  doAssert $(parseImage("127.0.0.1/bar").uri) == "http://127.0.0.1/v2/bar"
  doAssert $(parseImage("127.0.0.1:1234/bar").uri) == "http://127.0.0.1:1234/v2/bar"
  doAssert $(parseImage("localhost/bar").uri(scheme="https://")) == "https://localhost/v2/bar"

  doAssert $(parseImage("foo").uri(path = "/manifests/latest")) == "https://registry-1.docker.io/v2/library/foo/manifests/latest"

main()
