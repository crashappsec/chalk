#!/bin/bash
# Regenerate public-only security regression fixtures with OpenSSL >= 3.4.
# Ephemeral test private keys are created in scratch and removed on exit.
set -e
O=${OPENSSL:-openssl}
S=$(mktemp -d)
F=$(cd "$(dirname "$0")" && pwd)
trap 'rm -rf "$S"' EXIT
cd "$S"

"$O" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out pss.key 2>/dev/null
for digest in sha1 sha256; do
  "$O" req -x509 -new -key pss.key -"$digest" -sigopt rsa_padding_mode:pss \
    -subj "/CN=$digest-pss.example" -not_before 20200101000000Z \
    -not_after 21200101000000Z -out "$F/$digest-pss.pem"
done

# Copy the real test root's issuer identity, but use an unrelated private key.
ski=$("$O" x509 -in "$F/ca.pem" -noout -ext subjectKeyIdentifier | tail -n 1 | tr -d ' ')
cat > fake-ca.cnf <<EOF
[req]
distinguished_name=dn
[dn]
[v3]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=$ski
EOF
cat > leaf.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
"$O" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out fake-ca.key 2>/dev/null
"$O" req -x509 -new -key fake-ca.key -sha256 \
  -subj "/C=US/O=Chalk Test/CN=Chalk Test Root CA" \
  -not_before 20200101000000Z -not_after 21200101000000Z \
  -extensions v3 -config fake-ca.cnf -out "$F/spoofed-ca.pem"
"$O" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
"$O" req -new -key leaf.key -subj "/CN=spoofed-issuer.example" -out leaf.csr
"$O" x509 -req -in leaf.csr -CA "$F/spoofed-ca.pem" -CAkey fake-ca.key \
  -set_serial 1 -sha256 -not_before 20200101000000Z -not_after 21200101000000Z \
  -extfile leaf.ext -out "$F/spoofed-issuer.pem" 2>/dev/null
