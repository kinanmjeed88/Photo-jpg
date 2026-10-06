#!/usr/bin/env bash
#
# Creates a brand-new release signing identity (private key + self-signed
# certificate) and packages it as a PKCS#12 keystore that Gradle, keytool and
# apksigner all read without extra configuration.
#
# The keystore is written OUTSIDE the repository by default, and no password is
# ever printed: values are written to `<output-dir>/SETUP_SECRETS.txt` for the
# repository owner to copy into GitHub Actions secrets and then delete.
#
# Usage:
#   tool/generate_release_keystore.sh [output-dir] [alias] [organisation] [country]
#
# Defaults: ./signing-new, alias "photo-jpg-release",
#           organisation "Photo JPG", country "IQ"
#
# Requires: openssl. Does NOT require Java.
set -euo pipefail

OUT_DIR=${1:-./signing-new}
ALIAS=${2:-photo-jpg-release}
ORG=${3:-Photo JPG}
COUNTRY=${4:-IQ}
KEYSTORE_NAME=${KEYSTORE_NAME:-photo_jpg_release.p12}

command -v openssl >/dev/null \
    || { printf '[FAIL] openssl is required\n' >&2; exit 1; }

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 32 characters of CSPRNG output, URL-safe so every tool accepts it verbatim.
new_password() {
    python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
PY
}

STORE_PASSWORD=$(new_password)
KEY_PASSWORD=$STORE_PASSWORD   # PKCS#12 protects both with one passphrase

printf '%s' "$STORE_PASSWORD" > "$work/pass.txt"

openssl req -new -x509 -sha256 -nodes -newkey rsa:2048 -days 10000 \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -subj "/CN=$ALIAS/OU=Release/O=$ORG/C=$COUNTRY" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$ALIAS" -passout "file:$work/pass.txt" \
    -out "$OUT_DIR/$KEYSTORE_NAME"

chmod 600 "$OUT_DIR/$KEYSTORE_NAME"

# Public certificate details, useful as an auditable record of the identity.
openssl pkcs12 -in "$OUT_DIR/$KEYSTORE_NAME" -nokeys -clcerts \
    -passin "file:$work/pass.txt" 2>/dev/null \
    | openssl x509 -noout -subject -fingerprint -sha256 \
    > "$OUT_DIR/certificate.txt"

{
    echo "# Values for the GitHub Actions secrets of the release signing identity."
    echo "# Copy each value into the matching repository secret, then DELETE this"
    echo "# file and keep the keystore + passwords in your own secure storage."
    echo "# Creating these secrets is an owner action; CI has no permission to do it."
    echo
    echo "secret name            : KEYSTORE_BASE64"
    echo "value (single line)    :"
    echo "---8<---"
    base64 -w0 "$OUT_DIR/$KEYSTORE_NAME"
    echo
    echo "--->8---"
    echo
    echo "secret name            : STORE_PASSWORD"
    echo "value                  : $STORE_PASSWORD"
    echo
    echo "secret name            : KEY_ALIAS"
    echo "value                  : $ALIAS"
    echo
    echo "secret name            : KEY_PASSWORD"
    echo "value                  : $KEY_PASSWORD"
    echo
    echo "# Equivalent one-liners, run from a machine that holds the keystore:"
    echo "#   base64 -w0 $OUT_DIR/$KEYSTORE_NAME | gh secret set KEYSTORE_BASE64"
    echo "#   printf '%s' '<value above>'       | gh secret set STORE_PASSWORD"
    echo "#   printf '%s' '$ALIAS'              | gh secret set KEY_ALIAS"
    echo "#   printf '%s' '<value above>'       | gh secret set KEY_PASSWORD"
    echo
    echo "# Public certificate of the new identity (safe to share):"
    sed 's/^/#   /' "$OUT_DIR/certificate.txt"
} > "$OUT_DIR/SETUP_SECRETS.txt"
chmod 600 "$OUT_DIR/SETUP_SECRETS.txt"

printf 'keystore : %s\n' "$OUT_DIR/$KEYSTORE_NAME"
printf 'setup    : %s\n' "$OUT_DIR/SETUP_SECRETS.txt"
printf 'alias    : %s\n' "$ALIAS"
printf 'No password is printed here; it lives in the setup file only.\n'
