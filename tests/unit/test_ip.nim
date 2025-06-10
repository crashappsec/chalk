import std/net
import ../../src/utils/ip

proc main() =
  doAssert parseIpAddress("10.10.10.10") notin parseIpCidrRange("10.11.12.13/32")
  doAssert parseIpAddress("10.10.10.10") notin parseIpCidrRange("10.11.12.13/24")
  doAssert parseIpAddress("10.10.10.10") notin parseIpCidrRange("10.11.12.13/16")
  doAssert parseIpAddress("10.10.10.10") in    parseIpCidrRange("10.11.12.13/8")
  doAssert parseIpAddress("10.10.10.10") in    parseIpCidrRange("1.2.3.4/0")

  doAssert parseIpAddress("2001:df8:0:0:0:ab1:0:0") notin parseIpCidrRange("2001:db8::/128")
  doAssert parseIpAddress("2001:df8:0:0:0:ab1:0:0") notin parseIpCidrRange("2001:db8::/96")
  doAssert parseIpAddress("2001:db8:0:0:0:ab1:0:0") in    parseIpCidrRange("2001:db8::/64")
  doAssert parseIpAddress("2001:db8:0:0:0:ab1:0:0") in    parseIpCidrRange("2001:db8::/48")
  doAssert parseIpAddress("2001:db8:0:0:0:ab1:0:0") in    parseIpCidrRange("2001:db8::/16")
  doAssert parseIpAddress("2001:db8:0:0:0:ab1:0:0") in    parseIpCidrRange("2001:db8::/0")
  doAssert parseIpAddress("2001:ab1:0:0:0:ab1:0:0") notin parseIpCidrRange("2001:db8::/48")
  doAssert parseIpAddress("2001:ab1:0:0:0:ab1:0:0") notin parseIpCidrRange("100::/63")
  doAssert parseIpAddress("2001:ab1:0:0:0:ab1:0:0") notin parseIpCidrRange("100::/65")
  doAssert parseIpAddress("2001:ab1:0:0:0:ab1:0:0") notin parseIpCidrRange("100::/64")

  doAssert parseIpAddress("127.0.0.1").isSpecialPurpose()
  doAssert parseIpAddress("10.10.10.10").isSpecialPurpose()
  doAssert parseIpAddress("192.168.1.1").isSpecialPurpose()
  doAssert not parseIpAddress("1.1.1.1").isSpecialPurpose()
  doAssert not parseIpAddress("9.9.9.9").isSpecialPurpose()

  doAssert parseIpAddress("2001:0:0:0:0:ab1:0:0").isSpecialPurpose()
  doAssert not parseIpAddress("2001:df8:0:0:0:ab1:0:0").isSpecialPurpose()
  doAssert not parseIpAddress("d4c5:d0c5:c030:c94f:6fe7:70b7:a041:14f2").isSpecialPurpose()

main()
