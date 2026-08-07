#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: notarize_macos_release.sh [options] DISTRIBUTION_PATH

Submits a Developer ID-signed .dmg or app to Apple's notary service, then
staples and validates the accepted ticket. A .dmg is submitted and stapled
directly. When an app is supplied for backward compatibility, the script uses
a temporary ZIP submission and creates a final ZIP release asset.

Authentication (choose one):
  --keychain-profile NAME           notarytool Keychain profile. Defaults to
                                    mlx-vlm-server-notary when no API key is set.
  --key PATH --key-id ID [--issuer ID]
                                    App Store Connect API key

The corresponding environment variables are NOTARYTOOL_PROFILE,
NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER.

Options:
  --output PATH     Final ZIP path when DISTRIBUTION_PATH is an app. Not valid
                    for a .dmg, which is notarized in place.
  --timeout VALUE   notarytool wait timeout. Defaults to 30m.
  --validate-only   Run all local signature/container checks without submitting.
  -h, --help        Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

keychain_profile="${NOTARYTOOL_PROFILE:-}"
key_path="${NOTARY_KEY_PATH:-}"
key_id="${NOTARY_KEY_ID:-}"
issuer="${NOTARY_ISSUER:-}"
output_path=""
timeout="30m"
validate_only=false

while (($# > 0)); do
    case "$1" in
        --keychain-profile)
            (($# >= 2)) || fail "--keychain-profile requires a value"
            keychain_profile="$2"
            shift 2
            ;;
        --key)
            (($# >= 2)) || fail "--key requires a value"
            key_path="$2"
            shift 2
            ;;
        --key-id)
            (($# >= 2)) || fail "--key-id requires a value"
            key_id="$2"
            shift 2
            ;;
        --issuer)
            (($# >= 2)) || fail "--issuer requires a value"
            issuer="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || fail "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || fail "--timeout requires a value"
            timeout="$2"
            shift 2
            ;;
        --validate-only)
            validate_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# == 1)) || {
    usage >&2
    exit 2
}

distribution_path="$1"
is_disk_image=false
if [[ -f "$distribution_path" && "$distribution_path" == *.dmg ]]; then
    is_disk_image=true
elif [[ ! -d "$distribution_path" || ! -f "$distribution_path/Contents/Info.plist" ]]; then
    fail "distribution must be a macOS app bundle or .dmg disk image: $distribution_path"
fi
if [[ "$is_disk_image" == true && -n "$output_path" ]]; then
    fail "--output is only valid when notarizing an app bundle"
fi

distribution_directory="$(cd "$(dirname "$distribution_path")" && pwd -P)"
distribution_path="$distribution_directory/$(basename "$distribution_path")"

if [[ -z "$keychain_profile" && -z "$key_path" && -z "$key_id" && -z "$issuer" ]]; then
    keychain_profile="mlx-vlm-server-notary"
fi

authentication_arguments=()
if [[ -n "$keychain_profile" ]]; then
    [[ -z "$key_path" && -z "$key_id" && -z "$issuer" ]] || \
        fail "use either a Keychain profile or an API key, not both"
    authentication_arguments=(--keychain-profile "$keychain_profile")
else
    [[ -n "$key_path" && -n "$key_id" ]] || \
        fail "provide --keychain-profile or both --key and --key-id"
    [[ -f "$key_path" ]] || fail "API key file not found: $key_path"
    authentication_arguments=(--key "$key_path" --key-id "$key_id")
    if [[ -n "$issuer" ]]; then
        authentication_arguments+=(--issuer "$issuer")
    fi
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mlx-vlm-notary.XXXXXX")"
mount_path="$temporary_directory/mount"
is_mounted=false
cleanup() {
    if [[ "$is_mounted" == true ]]; then
        hdiutil detach "$mount_path" -quiet || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

if [[ "$is_disk_image" == true ]]; then
    codesign --verify --strict --verbose=2 "$distribution_path"
    disk_image_signature="$(codesign -dvvv "$distribution_path" 2>&1)"
    [[ "$disk_image_signature" == *"Authority=Developer ID Application:"* ]] || \
        fail "the disk image must be signed with a Developer ID Application certificate"
    [[ "$disk_image_signature" == *"Timestamp="* ]] || \
        fail "the disk image signature does not contain a secure timestamp"
    disk_image_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$disk_image_signature" | head -n 1)"
    [[ -n "$disk_image_team_identifier" && "$disk_image_team_identifier" != "not set" ]] || \
        fail "the disk image signature does not contain a Developer Team ID"

    mkdir -p "$mount_path"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount_path" "$distribution_path"
    is_mounted=true
    app_paths=()
    while IFS= read -r -d '' candidate; do
        app_paths+=("$candidate")
    done < <(find "$mount_path" -maxdepth 1 -type d -name '*.app' -print0)
    ((${#app_paths[@]} == 1)) || fail "disk image must contain exactly one top-level app bundle"
    app_path="${app_paths[0]}"
else
    app_path="$distribution_path"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details="$(codesign -dvvv "$app_path" 2>&1)"
if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
    fail "the app must be signed with a Developer ID Application certificate before notarization"
fi
[[ "$signature_details" == *"Timestamp="* ]] || \
    fail "the app signature does not contain a secure timestamp"
app_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature_details" | head -n 1)"
[[ -n "$app_team_identifier" && "$app_team_identifier" != "not set" ]] || \
    fail "the app signature does not contain a Developer Team ID"
if [[ "$is_disk_image" == true && "$disk_image_team_identifier" != "$app_team_identifier" ]]; then
    fail "the disk image and contained app have different Team IDs"
fi

native_code_count=0
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    [[ "$file_type" == Mach-O* ]] || continue

    codesign --verify --strict "$candidate"
    candidate_signature="$(codesign -dvvv "$candidate" 2>&1)"
    [[ "$candidate_signature" == *"Authority=Developer ID Application:"* ]] || \
        fail "native code is not Developer ID signed: $candidate"
    [[ "$candidate_signature" == *"TeamIdentifier=$app_team_identifier"* ]] || \
        fail "native code has a different Team ID: $candidate"
    [[ "$candidate_signature" == *"runtime"* ]] || \
        fail "native code is missing the hardened-runtime flag: $candidate"
    [[ "$candidate_signature" == *"Timestamp="* ]] || \
        fail "native code is missing a secure timestamp: $candidate"
    ((native_code_count += 1))
done < <(find "$app_path" -type f -print0)
echo "Verified $native_code_count Developer ID-signed Mach-O files."

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
if [[ "$app_entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    fail "the app contains the development-only get-task-allow entitlement"
fi

info_plist="$app_path/Contents/Info.plist"
bundle_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true
)"
[[ -n "$bundle_identifier" ]] || fail "CFBundleIdentifier is missing from $info_plist"
app_name="$(basename "$app_path" .app)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
[[ -n "$version" ]] || fail "CFBundleShortVersionString is missing from $info_plist"

embedded_profile="$app_path/Contents/embedded.provisionprofile"
[[ -f "$embedded_profile" ]] || fail "the app is missing Contents/embedded.provisionprofile"
profile_plist="$temporary_directory/embedded-profile.plist"
security cms -D -i "$embedded_profile" > "$profile_plist" || \
    fail "the embedded provisioning profile has an invalid signature"

profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
profile_team_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist"
)"
profile_application_identifier="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.application-identifier' \
        "$profile_plist"
)"
expected_application_identifier="$app_team_identifier.$bundle_identifier"
[[ "$profile_team_identifier" == "$app_team_identifier" ]] || \
    fail "profile $profile_name belongs to Team $profile_team_identifier, expected $app_team_identifier"
[[ "$profile_application_identifier" == "$expected_application_identifier" ]] || \
    fail "profile $profile_name authorizes $profile_application_identifier, expected $expected_application_identifier"

app_entitlements_plist="$temporary_directory/app-entitlements.plist"
printf '%s' "$app_entitlements" > "$app_entitlements_plist"
plutil -lint "$app_entitlements_plist" >/dev/null || \
    fail "the app's signed entitlements could not be decoded"
signed_application_identifier="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.application-identifier' \
        "$app_entitlements_plist" 2>/dev/null || true
)"
signed_entitlement_team_identifier="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.team-identifier' \
        "$app_entitlements_plist" 2>/dev/null || true
)"
signed_keychain_group="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :keychain-access-groups:0' \
        "$app_entitlements_plist" 2>/dev/null || true
)"
[[ "$signed_application_identifier" == "$expected_application_identifier" ]] || \
    fail "the app signature has an unexpected application identifier: $signed_application_identifier"
[[ "$signed_entitlement_team_identifier" == "$app_team_identifier" ]] || \
    fail "the app signature has an unexpected entitlement Team ID: $signed_entitlement_team_identifier"
[[ "$signed_keychain_group" == "$expected_application_identifier" ]] || \
    fail "the app signature has an unexpected Keychain group: $signed_keychain_group"

profile_keychain_group=""
profile_keychain_group_index=0
profile_authorizes_keychain_group=false
while profile_keychain_group="$(
    /usr/libexec/PlistBuddy \
        -c "Print :Entitlements:keychain-access-groups:$profile_keychain_group_index" \
        "$profile_plist" 2>/dev/null
)"; do
    if [[ "$profile_keychain_group" == "$signed_keychain_group" || \
          "$profile_keychain_group" == "$app_team_identifier.*" ]]; then
        profile_authorizes_keychain_group=true
        break
    fi
    ((profile_keychain_group_index += 1))
done
[[ "$profile_authorizes_keychain_group" == true ]] || \
    fail "profile $profile_name does not authorize Keychain group $signed_keychain_group"
echo "Verified embedded provisioning profile: $profile_name"

if [[ "$validate_only" == true ]]; then
    if [[ "$is_disk_image" == true ]]; then
        hdiutil detach "$mount_path" -quiet
        is_mounted=false
    fi
    echo "Local notarization preflight passed: $distribution_path"
    exit 0
fi

if [[ "$is_disk_image" == true ]]; then
    hdiutil detach "$mount_path" -quiet
    is_mounted=false
    submission_path="$distribution_path"
    result_directory="$distribution_directory"
else
    if [[ -z "$output_path" ]]; then
        output_path="dist/release/${app_name}-${version}.zip"
    fi
    output_directory="$(dirname "$output_path")"
    mkdir -p "$output_directory"
    output_directory="$(cd "$output_directory" && pwd -P)"
    output_path="$output_directory/$(basename "$output_path")"
    submission_path="$temporary_directory/${app_name}-${version}.zip"
    result_directory="$output_directory"

    echo "Creating notarization submission archive..."
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_path"
fi

result_path="$result_directory/${app_name}-${version}-notary-result.json"
log_path="$result_directory/${app_name}-${version}-notary-log.json"

echo "Submitting $(basename "$submission_path") to Apple's notary service..."
set +e
xcrun notarytool submit \
    "${authentication_arguments[@]}" \
    --wait \
    --timeout "$timeout" \
    --no-progress \
    --output-format json \
    "$submission_path" > "$result_path"
submission_exit_code=$?
set -e

notary_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"

if [[ "$submission_exit_code" -ne 0 || "$notary_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log \
            "${authentication_arguments[@]}" \
            "$submission_id" \
            "$log_path" || true
    fi
    fail "notarization failed with exit code $submission_exit_code and status '${notary_status:-unknown}'; see $result_path and $log_path"
fi

echo "Stapling notarization ticket..."
if [[ "$is_disk_image" == true ]]; then
    xcrun stapler staple "$distribution_path"
    xcrun stapler validate "$distribution_path"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$distribution_path"
    echo "Notarized release asset: $distribution_path"
else
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"

    echo "Creating final release archive..."
    rm -f "$output_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"
    echo "Notarized release asset: $output_path"
fi
echo "Notary result: $result_path"
