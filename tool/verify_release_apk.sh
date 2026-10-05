#!/usr/bin/env bash
#
# Verifies that a release APK is really signed with this project's release
# signing identity, that it is not debug-signed, and that its identity metadata
# (applicationId, versionName, versionCode) did not drift.
#
# Only public information is printed: certificate subject, certificate SHA-256
# digest, package name, version and the verified signature schemes. Passwords
# and the location of the keystore are never printed.
#
# Usage:
#   tool/verify_release_apk.sh <apk> <applicationId> <versionName> <versionCode>
#
# Expected release identity (optional; when absent the check fails on purpose,
# because verifying a release APK against nothing is not a verification):
#   RELEASE_KEYSTORE         path to the release keystore (or PHOTOJPG_STORE_FILE)
#   PHOTOJPG_STORE_PASSWORD  store password of that keystore
#   PHOTOJPG_KEY_ALIAS       alias of the release key
#
# Exit code 0 means: signature valid, single signer, not the debug key, identity
# metadata unchanged. Anything else is a hard failure.
set -euo pipefail

APK=${1:?usage: verify_release_apk.sh <apk> <applicationId> <versionName> <versionCode>}
EXPECTED_APP_ID=${2:?missing expected applicationId}
EXPECTED_VERSION_NAME=${3:?missing expected versionName}
EXPECTED_VERSION_CODE=${4:?missing expected versionCode}

RELEASE_KEYSTORE=${RELEASE_KEYSTORE:-${PHOTOJPG_STORE_FILE:-}}
PHOTOJPG_STORE_PASSWORD=${PHOTOJPG_STORE_PASSWORD:-}
PHOTOJPG_KEY_ALIAS=${PHOTOJPG_KEY_ALIAS:-}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

[ -f "$APK" ] || fail "APK not found: $APK"

SDK_ROOT=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
[ -n "$SDK_ROOT" ] || fail "ANDROID_SDK_ROOT / ANDROID_HOME is not set"

# Newest build-tools first: the tools have to be able to read the newest
# signature schemes.
find_tool() {
    local name=$1 candidate
    candidate=$(find "$SDK_ROOT/build-tools" -maxdepth 2 -type f -name "$name" \
        2>/dev/null | sort -V | tail -n 1)
    [ -n "$candidate" ] || candidate=$(command -v "$name" || true)
    [ -n "$candidate" ] || fail "cannot find '$name' in the Android SDK"
    printf '%s' "$candidate"
}

APKSIGNER=$(find_tool apksigner)
AAPT=$(find_tool aapt2 2>/dev/null || true)
[ -n "$AAPT" ] || AAPT=$(find_tool aapt)

# Normalises a digest to lower-case hex so that the colon-separated keytool
# output and the compact apksigner output can be compared.
normalise_digest() {
    tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f'
}

echo "== APK signature =="
SIGNATURE_REPORT=$("$APKSIGNER" verify --verbose --print-certs "$APK" 2>&1) \
    || fail "apksigner rejected the APK signature"
printf '%s\n' "$SIGNATURE_REPORT"

SIGNER_COUNT=$(printf '%s\n' "$SIGNATURE_REPORT" | grep -c '^Signer #' || true)
SIGNER_CERT_COUNT=$(printf '%s\n' "$SIGNATURE_REPORT" \
    | grep -c 'certificate SHA-256 digest' || true)
[ "$SIGNER_CERT_COUNT" -ge 1 ] || fail "the report lists no signer certificate"
[ "$SIGNER_CERT_COUNT" -eq 1 ] \
    || fail "expected exactly one signer, found $SIGNER_CERT_COUNT"

APK_DIGEST=$(printf '%s\n' "$SIGNATURE_REPORT" \
    | grep 'certificate SHA-256 digest' | head -n 1 \
    | sed 's/^.*digest: *//' | normalise_digest || true)
APK_SUBJECT=$(printf '%s\n' "$SIGNATURE_REPORT" \
    | grep 'certificate DN' | head -n 1 | sed 's/^.*DN: *//' || true)
[ -n "$APK_DIGEST" ] || fail "cannot read the signer certificate digest"

echo "signer subject : $APK_SUBJECT"
echo "signer sha-256 : $APK_DIGEST"
echo "signers        : $SIGNER_CERT_COUNT (schemes checked by apksigner above)"

# A build that silently fell back to the debug key must never pass verification,
# no matter what the caller expected.
case "$APK_SUBJECT" in
    *'CN=Android Debug'*)
        fail "the APK is signed with the Android debug key, so it must not be \
shipped: no release signing material was available. Configure \
PHOTOJPG_KEYSTORE_BASE64 + PHOTOJPG_STORE_PASSWORD + PHOTOJPG_KEY_ALIAS (or a \
single PHOTOJPG_KEY_PROPERTIES_BASE64) and re-run."
        ;;
esac

DEBUG_KEYSTORE=${HOME:-}/.android/debug.keystore
if [ -f "$DEBUG_KEYSTORE" ]; then
    DEBUG_DIGEST=$(keytool -list -v -keystore "$DEBUG_KEYSTORE" \
        -storepass android -alias androiddebugkey 2>/dev/null \
        | grep -i 'SHA256:' | head -n 1 | sed 's/^.*SHA256: *//' \
        | normalise_digest || true)
    if [ -n "$DEBUG_DIGEST" ] && [ "$DEBUG_DIGEST" = "$APK_DIGEST" ]; then
        fail "the APK is signed with the debug key from $DEBUG_KEYSTORE"
    fi
fi

# Same signing identity as the project's keystore: compare the public
# certificate digest of the APK with the certificate inside the keystore.
[ -n "$RELEASE_KEYSTORE" ] && [ -f "$RELEASE_KEYSTORE" ] \
    || fail "no release keystore was provided, so the signing identity cannot be \
confirmed: provide the repository secrets PHOTOJPG_KEYSTORE_BASE64 / \
PHOTOJPG_STORE_PASSWORD / PHOTOJPG_KEY_ALIAS (or an existing `key.properties`), \
then re-run this check"
[ -n "$PHOTOJPG_STORE_PASSWORD" ] \
    || fail "PHOTOJPG_STORE_PASSWORD is not set; cannot read the release keystore"

KEYTOOL_ARGS=(-list -v -keystore "$RELEASE_KEYSTORE" \
    -storepass "$PHOTOJPG_STORE_PASSWORD")
[ -n "$PHOTOJPG_KEY_ALIAS" ] && KEYTOOL_ARGS+=(-alias "$PHOTOJPG_KEY_ALIAS")
EXPECTED_DIGEST=$(keytool "${KEYTOOL_ARGS[@]}" 2>/dev/null \
    | grep -i 'SHA256:' | head -n 1 | sed 's/^.*SHA256: *//' | normalise_digest \
    || true)
[ -n "$EXPECTED_DIGEST" ] \
    || fail "cannot read the release certificate from the provided keystore \
(check PHOTOJPG_KEY_ALIAS / PHOTOJPG_STORE_PASSWORD)"

[ "$EXPECTED_DIGEST" = "$APK_DIGEST" ] \
    || fail "signing identity mismatch: the APK certificate is not the one in \
the release keystore"
echo "identity       : matches the release keystore certificate (same SHA-256)"

echo
echo "== Identity metadata =="
BADGING=$("$AAPT" dump badging "$APK" 2>/dev/null) \
    || fail "cannot read the APK manifest"
PACKAGE_LINE=$(printf '%s\n' "$BADGING" | grep "^package: " | head -n 1 || true)
ACTUAL_APP_ID=$(printf '%s\n' "$PACKAGE_LINE" \
    | sed -n "s/^package: name='\([^']*\)'.*/\1/p" || true)
ACTUAL_VERSION_CODE=$(printf '%s\n' "$PACKAGE_LINE" \
    | sed -n "s/^.*versionCode='\([^']*\)'.*/\1/p" || true)
ACTUAL_VERSION_NAME=$(printf '%s\n' "$PACKAGE_LINE" \
    | sed -n "s/^.*versionName='\([^']*\)'.*/\1/p" || true)
printf 'applicationId : %s\nversionName   : %s\nversionCode   : %s\n' \
    "$ACTUAL_APP_ID" "$ACTUAL_VERSION_NAME" "$ACTUAL_VERSION_CODE"

[ -n "$ACTUAL_APP_ID" ] || fail "cannot read the package name from the APK"
[ "$ACTUAL_APP_ID" = "$EXPECTED_APP_ID" ] \
    || fail "applicationId changed: expected '$EXPECTED_APP_ID'"
[ "$ACTUAL_VERSION_NAME" = "$EXPECTED_VERSION_NAME" ] \
    || fail "versionName changed: expected '$EXPECTED_VERSION_NAME'"
[ "$ACTUAL_VERSION_CODE" = "$EXPECTED_VERSION_CODE" ] \
    || fail "versionCode changed: expected '$EXPECTED_VERSION_CODE'"

echo
echo '[PASS] signature valid, release identity confirmed, not debug-signed,'
echo '[PASS] applicationId / versionName / versionCode unchanged.'
