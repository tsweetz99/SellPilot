#!/bin/sh
# Makes the throwaway certificate chain the Apple signature tests use: root -> intermediate -> leaf, shaped like Apple's
# (P-384 root and intermediate, P-256 leaf, and the Apple marker extensions). These keys sign nothing real.
# Run once and commit the output; the tests never need openssl.
set -e
cd "$(dirname "$0")"
rm -f *.pem *.cnf
LEAF_OID=1.2.840.113635.100.6.11.1
INTERMEDIATE_OID=1.2.840.113635.100.6.2.1
openssl ecparam -name secp384r1 -genkey -noout -out root.key.pem
openssl req -new -x509 -key root.key.pem -sha384 -days 36500 -subj "/CN=Test Root CA/O=SellPilot Tests" -out root.pem
for name in intermediate leaf; do
  if [ $name = intermediate ]; then openssl ecparam -name secp384r1 -genkey -noout -out $name.key.pem; else openssl ecparam -name prime256v1 -genkey -noout -out $name.key.pem; fi
done
openssl req -new -key intermediate.key.pem -subj "/CN=Test Intermediate/O=SellPilot Tests" -out intermediate.csr
printf "basicConstraints=critical,CA:TRUE\n$INTERMEDIATE_OID=ASN1:NULL\n" > intermediate.cnf
openssl x509 -req -in intermediate.csr -CA root.pem -CAkey root.key.pem -CAcreateserial -sha384 -days 36500 -extfile intermediate.cnf -out intermediate.pem
openssl req -new -key leaf.key.pem -subj "/CN=Test Leaf/O=SellPilot Tests" -out leaf.csr
printf "basicConstraints=critical,CA:FALSE\n$LEAF_OID=ASN1:NULL\n" > leaf.cnf
openssl x509 -req -in leaf.csr -CA intermediate.pem -CAkey intermediate.key.pem -CAcreateserial -sha256 -days 36500 -extfile leaf.cnf -out leaf.pem
# A second, unrelated root, to prove a chain that does not lead to the trusted root is refused.
openssl ecparam -name secp384r1 -genkey -noout -out other-root.key.pem
openssl req -new -x509 -key other-root.key.pem -sha384 -days 36500 -subj "/CN=Other Root/O=Elsewhere" -out other-root.pem
rm -f *.csr *.cnf *.srl
