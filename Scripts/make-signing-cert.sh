#!/bin/bash
# Create a stable, self-signed code-signing identity in your login keychain so
# macOS privacy (TCC) grants -- Automation / Accessibility / Notifications --
# PERSIST across Buildwright rebuilds.
#
# Why: TCC keys a grant to the app's code signature. Ad-hoc signing
# (codesign --sign -) produces a different signature every build, so each
# reinstall looks like a brand-new app and every "Allow" is forgotten. A fixed
# identity gives Buildwright one stable signature, so a one-time Allow sticks.
#
# Run ONCE:  Scripts/make-signing-cert.sh
# Then rebuild (Scripts/bundle.sh) -- it auto-detects and uses this identity.
# Safe to re-run: it no-ops if the identity already exists.

set -euo pipefail

NAME="${BW_SIGN_IDENTITY:-Buildwright Self-Signed}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "${NAME}"; then
  echo "OK: code-signing identity [${NAME}] already exists -- nothing to do."
  exit 0
fi

echo "Creating self-signed code-signing identity [${NAME}] ..."
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Self-signed cert with the codeSigning extended key usage -- the only EKU
# codesign requires. No CA, valid 10 years.
cat > "${TMP}/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions   = v3
prompt            = no
[dn]
CN = ${NAME}
[v3]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" -config "${TMP}/req.cnf" >/dev/null 2>&1

# OpenSSL 3 defaults to a PKCS#12 MAC macOS's `security` can't verify; -legacy
# restores the algorithms it accepts. LibreSSL (no -legacy flag) already uses
# them, so only add it when supported.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi
openssl pkcs12 -export ${LEGACY} -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
  -name "${NAME}" -out "${TMP}/id.p12" -passout pass:buildwright >/dev/null 2>&1

# -A: any app may use the private key without a per-use keychain prompt (this
# is a personal local-signing key, not a secret). -T codesign is belt-and-
# suspenders for the same.
security import "${TMP}/id.p12" -k "${KEYCHAIN}" -P buildwright \
  -A -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -q "${NAME}"; then
  echo "OK: created [${NAME}]. Now rebuild:  Scripts/bundle.sh"
  echo "    After the next install, grant each prompt once in Buildwright ->"
  echo "    Settings -> Permissions; it will stick across future updates."
else
  echo "FAILED: identity not found after import. Create it manually:"
  echo "  Keychain Access -> Certificate Assistant -> Create a Certificate ->"
  echo "  name it [${NAME}], type: Code Signing, self-signed."
  exit 1
fi
