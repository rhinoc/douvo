#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BUILD_CERTIFICATE_BASE64:-}" ]]; then
  echo "No BUILD_CERTIFICATE_BASE64 secret; using local keychain identities."
  exit 0
fi

: "${P12_PASSWORD:?P12_PASSWORD is required when BUILD_CERTIFICATE_BASE64 is set}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD is required when BUILD_CERTIFICATE_BASE64 is set}"

CERTIFICATE_PATH="${RUNNER_TEMP:-/tmp}/douvo-code-signing.p12"
CERTIFICATE_PEM="${RUNNER_TEMP:-/tmp}/douvo-code-signing.pem"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/douvo-signing.keychain-db"
EXISTING_KEYCHAINS=()
while IFS= read -r keychain; do
  EXISTING_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')

echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o "$CERTIFICATE_PATH"
openssl pkcs12 -in "$CERTIFICATE_PATH" -passin "pass:$P12_PASSWORD" -clcerts -nokeys -out "$CERTIFICATE_PEM"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$P12_PASSWORD" -A -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null
security add-trusted-cert -p codeSign -k "$KEYCHAIN_PATH" "$CERTIFICATE_PEM" >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1
security list-keychains -d user -s "$KEYCHAIN_PATH" "${EXISTING_KEYCHAINS[@]}"

IDENTITY="$(
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | awk -F'"' '/"[^"]+"/ { print $2; exit }'
)"

if [[ -z "$IDENTITY" ]]; then
  echo "error: imported certificate did not produce a valid codesigning identity" >&2
  exit 1
fi

echo "Imported codesigning identity: $IDENTITY"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "CODESIGN_IDENTITY=$IDENTITY"
    echo "CODESIGN_KEYCHAIN=$KEYCHAIN_PATH"
  } >>"$GITHUB_ENV"
fi

rm -f "$CERTIFICATE_PATH" "$CERTIFICATE_PEM"
