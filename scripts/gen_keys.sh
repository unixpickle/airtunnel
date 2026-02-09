#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEY_DIR="${ROOT_DIR}/keys"
PRIV_PEM="${KEY_DIR}/server_private.pem"
PUB_PEM="${KEY_DIR}/server_public.pem"
DART_PUB="${ROOT_DIR}/lib/public_key.dart"

mkdir -p "${KEY_DIR}"

if [[ -f "${PRIV_PEM}" ]]; then
  echo "Private key already exists at ${PRIV_PEM}" >&2
  exit 1
fi

openssl genpkey -algorithm ED25519 -out "${PRIV_PEM}"
openssl pkey -in "${PRIV_PEM}" -pubout -out "${PUB_PEM}"

PUB_B64=$(openssl pkey -pubin -in "${PUB_PEM}" -outform DER | tail -c 32 | base64)

cat > "${DART_PUB}" <<EOF2
const String serverPublicKeyBase64 = '${PUB_B64}';
EOF2

echo "Wrote private key: ${PRIV_PEM}"
echo "Wrote public key:  ${PUB_PEM}"
echo "Updated Dart public key: ${DART_PUB}"
