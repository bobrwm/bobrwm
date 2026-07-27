#!/usr/bin/env bash
# Create a stable self-signed code-signing identity for local bobrwm builds.
#
# macOS keys Accessibility (TCC) grants to a binary's designated requirement.
# Ad-hoc signatures derive that requirement from the code hash, so every
# rebuild looks like a different app and silently drops the grant. Signing
# against a fixed certificate keeps the requirement constant and the grant
# sticky across rebuilds.
#
# Uses /usr/bin/openssl explicitly: a Homebrew OpenSSL 3 on PATH writes
# PKCS#12 files that `security import` rejects.

set -euo pipefail

identity="${1:-bobrwm Development}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$identity"; then
    echo "identity already present: $identity"
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat >"$workdir/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $identity

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$workdir/openssl.cnf" \
    -keyout "$workdir/key.pem" \
    -out "$workdir/cert.pem" 2>/dev/null

/usr/bin/openssl pkcs12 -export \
    -inkey "$workdir/key.pem" \
    -in "$workdir/cert.pem" \
    -out "$workdir/identity.p12" \
    -passout pass:

security import "$workdir/identity.p12" -k "$keychain" -P "" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$workdir/cert.pem"

echo
echo "created identity: $identity"
echo "build with: zig build -Dcodesign-identity=\"$identity\""
