#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: verify_macos_appcast.sh APPCAST_URL [EXPECTED_ARCHIVE_URL] [EXPECTED_APPCAST]

Downloads and validates a published Sparkle appcast, including its XML,
EdDSA signature metadata, enclosure length, downloadable release archive, and
optionally byte-for-byte equality with the expected local appcast.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

(($# >= 1 && $# <= 3)) || {
    usage >&2
    exit 2
}

appcast_url="$1"
expected_archive_url="${2:-}"
expected_appcast_path="${3:-}"
[[ "$appcast_url" == https://* ]] || fail "appcast URL must use HTTPS: $appcast_url"
if [[ -n "$expected_appcast_path" ]]; then
    [[ -f "$expected_appcast_path" ]] || fail "expected appcast not found: $expected_appcast_path"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/nativ-appcast-verification.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
appcast_path="$temporary_directory/appcast.xml"

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 12 \
    --retry-delay 10 \
    --retry-all-errors \
    --output "$appcast_path" \
    "$appcast_url"

[[ -s "$appcast_path" ]] || fail "published appcast is empty: $appcast_url"
xmllint --noout "$appcast_path"
if [[ -n "$expected_appcast_path" ]] && ! cmp -s "$expected_appcast_path" "$appcast_path"; then
    fail "published appcast does not match $expected_appcast_path: $appcast_url"
fi

enclosure_xpath='string((//*[local-name()="enclosure"])[1]/@url)'
signature_xpath='string((//*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])'
length_xpath='string((//*[local-name()="enclosure"])[1]/@length)'
archive_url="$(xmllint --xpath "$enclosure_xpath" "$appcast_path")"
signature="$(xmllint --xpath "$signature_xpath" "$appcast_path")"
archive_length="$(xmllint --xpath "$length_xpath" "$appcast_path")"

[[ "$archive_url" == https://* ]] || fail "appcast enclosure is missing a valid HTTPS URL"
[[ -n "$signature" ]] || fail "appcast enclosure is missing sparkle:edSignature"
[[ "$archive_length" =~ ^[1-9][0-9]*$ ]] || fail "appcast enclosure has an invalid length: $archive_length"
if [[ -n "$expected_archive_url" && "$archive_url" != "$expected_archive_url" ]]; then
    fail "appcast enclosure URL is $archive_url; expected $expected_archive_url"
fi

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --head \
    --retry 6 \
    --retry-all-errors \
    --output /dev/null \
    "$archive_url"

echo "Verified Sparkle appcast: $appcast_url"
echo "Verified release archive: $archive_url"
