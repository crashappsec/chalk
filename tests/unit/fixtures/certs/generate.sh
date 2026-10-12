#!/bin/bash
# Regenerates the certificate fixtures of tests/unit/test_policy_certificates.nim
# (update the fingerprints there afterwards). Needs OpenSSL >= 3.4 for
# -not_before/-not_after. Private keys stay in a temporary directory.
set -e
O=${OPENSSL:-openssl}
S=$(mktemp -d)
F=$(cd "$(dirname "$0")" && pwd)
trap "rm -rf $S" EXIT; cd $S
cat > ca.ext <<'EOF'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EOF
cat > leaf.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
cat > self.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
subjectKeyIdentifier=hash
EOF
cfg() { printf '[req]\ndistinguished_name=dn\n[dn]\n[v3]\n'; cat $1; }
cfg ca.ext > ca.cnf; cfg self.ext > self.cnf
$O genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ca.key 2>/dev/null
$O req -x509 -new -key ca.key -sha256 -subj "/C=US/O=Chalk Test/CN=Chalk Test Root CA" -not_before 20200101000000Z -not_after 21200101000000Z -extensions v3 -config ca.cnf -out ca.pem
leaf() { # name cn sigdigest notbefore notafter keyargs...
  local name=$1 cn=$2 dg=$3 nb=$4 na=$5; shift 5
  $O genpkey "$@" -out $name.key 2>/dev/null
  $O req -new -key $name.key -subj "/C=US/O=Chalk Test/CN=$cn" -out $name.csr
  $O x509 -req -in $name.csr -CA ca.pem -CAkey ca.key -set_serial 0x$($O rand -hex 8) -$dg -not_before $nb -not_after $na -extfile leaf.ext -out $name.pem 2>/dev/null
}
leaf leaf leaf.example.com sha256 20200101000000Z 21200101000000Z -algorithm EC -pkeyopt ec_paramgen_curve:P-256
leaf expired expired.example.com sha256 20190101000000Z 20200101000000Z -algorithm RSA -pkeyopt rsa_keygen_bits:2048
leaf future future.example.com sha256 21000101000000Z 21200101000000Z -algorithm RSA -pkeyopt rsa_keygen_bits:2048
leaf weak-rsa weak.example.com sha256 20200101000000Z 21200101000000Z -algorithm RSA -pkeyopt rsa_keygen_bits:1024
leaf sha1 sha1.example.com sha1 20200101000000Z 21200101000000Z -algorithm RSA -pkeyopt rsa_keygen_bits:2048
$O genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out self.key
$O req -x509 -new -key self.key -sha384 -subj "/CN=self.example.com" -not_before 20200101000000Z -not_after 21200101000000Z -extensions v3 -config self.cnf -out self-signed.pem
$O x509 -in leaf.pem -outform DER -out leaf.der
cat leaf.pem ca.pem > chain.pem
for f in ca leaf expired future weak-rsa sha1 self-signed; do cp $f.pem $F/; done
cp leaf.der chain.pem $F/
$O x509 -in ca.pem -noout -fingerprint -sha256
$O x509 -in self-signed.pem -noout -fingerprint -sha256
