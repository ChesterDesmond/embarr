#!/bin/bash
# One-time setup on the Mac that builds releases: makes the self-signed "Embarr" code-signing certificate in its own
# keychain (~/Library/Keychains/embarr-signing.keychain-db, password in ~/.config/embarr-signing/password), so
# scripts/bundle.sh can sign without prompts. Every release must be signed by the SAME certificate: the in-app updater
# refuses an update signed by any other, so back up ~/.config/embarr-signing/ (embarr.p12 + password). To move it to
# another Mac, copy that folder over and run this script: it imports the existing embarr.p12 instead of making a new one.
set -euo pipefail
D="$HOME/.config/embarr-signing"; KC="$HOME/Library/Keychains/embarr-signing.keychain-db"
mkdir -p "$D"; chmod 700 "$D"; cd "$D"
[ -f password ] || { openssl rand -hex 24 > password; chmod 600 password; }
PW="$(cat password)"
if [ ! -f embarr.p12 ]; then
  cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Embarr
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
  openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out embarr.p12 -passout "pass:$PW" -name Embarr 2>/dev/null \
    || openssl pkcs12 -export -inkey key.pem -in cert.pem -out embarr.p12 -passout "pass:$PW" -name Embarr
  rm -f key.pem; chmod 600 embarr.p12
fi
[ -f "$KC" ] || security create-keychain -p "$PW" embarr-signing.keychain
security unlock-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security find-identity -p codesigning "$KC" | grep -q '"Embarr"' || security import embarr.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security list-keychains -d user | grep -q embarr-signing || security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
security find-identity -p codesigning "$KC"
