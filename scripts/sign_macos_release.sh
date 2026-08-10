#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sign_macos_release.sh [options] TARGET

Signs every Mach-O file inside a macOS app from the inside out, then signs
nested code bundles and the app itself. TARGET may also be a .dmg disk image;
in that case, only the disk image container is signed.

Options:
  --identity ID              Codesigning identity name or SHA-1 hash.
  --team-id ID               Resolve a certificate whose subject OU matches this
                             Team ID. If neither option is provided,
                             DEVELOPMENT_TEAM is read from the Release build
                             settings.
  --provisioning-profile PATH
                             Profile to embed in an app. Developer ID signing
                             defaults to Nativ's checked-in encoded profile.
  --no-timestamp             Disable the secure timestamp for local development
                             testing. This selects Apple Development for Team ID
                             resolution and is rejected for Developer ID
                             Application identities.
  -h, --help                 Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
identity="${CODE_SIGN_IDENTITY:-}"
team_id="${NATIV_TEAM_ID:-}"
provisioning_profile="${NATIV_PROVISIONING_PROFILE:-}"
use_timestamp=true

while (($# > 0)); do
    case "$1" in
        --identity)
            (($# >= 2)) || fail "--identity requires a value"
            identity="$2"
            shift 2
            ;;
        --team-id)
            (($# >= 2)) || fail "--team-id requires a value"
            team_id="$2"
            shift 2
            ;;
        --provisioning-profile)
            (($# >= 2)) || fail "--provisioning-profile requires a value"
            provisioning_profile="$2"
            shift 2
            ;;
        --no-timestamp)
            use_timestamp=false
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

target_path="$1"
is_disk_image=false
if [[ -f "$target_path" && "$target_path" == *.dmg ]]; then
    is_disk_image=true
elif [[ ! -d "$target_path" || ! -d "$target_path/Contents" ]]; then
    fail "target must be a macOS app bundle or .dmg disk image: $target_path"
fi

target_directory="$(cd "$(dirname "$target_path")" && pwd -P)"
target_path="$target_directory/$(basename "$target_path")"
app_path="$target_path"

if [[ "$is_disk_image" == true && -n "$provisioning_profile" ]]; then
    fail "--provisioning-profile cannot be used when signing a disk image"
fi

[[ -z "$identity" || -z "$team_id" ]] || fail "use either --identity or --team-id, not both"

if [[ -z "$identity" && -z "$team_id" ]]; then
    team_id="$(
        xcodebuild \
            -project "$repository_root/Nativ.xcodeproj" \
            -scheme Nativ \
            -configuration Release \
            -showBuildSettings 2>/dev/null |
            sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' |
            sort -u |
            head -n 1
    )"
    [[ -n "$team_id" ]] || fail "could not infer DEVELOPMENT_TEAM; pass --team-id or --identity"
    echo "Using DEVELOPMENT_TEAM from Release build settings: $team_id"
fi

if [[ -n "$team_id" ]]; then
    [[ "$team_id" =~ ^[[:alnum:]]{10}$ ]] || fail "invalid Team ID: $team_id"
    command -v openssl >/dev/null 2>&1 || fail "openssl is required to resolve a Team ID"

    certificate_kind="Developer ID Application"
    if [[ "$use_timestamp" == false ]]; then
        certificate_kind="Apple Development"
    fi

    matching_hashes=()
    matching_names=()
    while IFS= read -r identity_candidate; do
        certificate_hash="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$identity_candidate")"
        certificate_name="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' <<< "$identity_candidate")"
        [[ -n "$certificate_hash" && "$certificate_name" == "$certificate_kind:"* ]] || continue

        certificate_subject="$(
            security find-certificate -c "$certificate_name" -p 2>/dev/null |
                openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true
        )"
        [[ "$certificate_subject" == *"OU=$team_id"* ]] || continue
        matching_hashes+=("$certificate_hash")
        matching_names+=("$certificate_name")
    done < <(security find-identity -v -p codesigning 2>/dev/null)

    if ((${#matching_hashes[@]} == 0)); then
        fail "no $certificate_kind certificate found for Team ID $team_id"
    fi
    if ((${#matching_hashes[@]} > 1)); then
        echo "error: multiple $certificate_kind certificates found for Team ID $team_id:" >&2
        for certificate_name in "${matching_names[@]}"; do
            echo "  $certificate_name" >&2
        done
        fail "pass --identity to choose one explicitly"
    fi

    identity="${matching_hashes[0]}"
    identity_display_name="${matching_names[0]}"
    echo "Resolved signing identity: $identity_display_name"
fi

identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" | head -n 1 || true)"
[[ -n "$identity_line" ]] || fail "codesigning identity not found: $identity"

signing_identity_hash="$(
    sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$identity_line"
)"
[[ -n "$signing_identity_hash" ]] || fail "could not resolve the signing identity hash"

signing_team_id="$team_id"
if [[ -z "$signing_team_id" ]]; then
    command -v openssl >/dev/null 2>&1 || \
        fail "openssl is required to resolve the signing certificate Team ID"

    certificate_name="$(
        sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' \
            <<< "$identity_line"
    )"
    [[ -n "$certificate_name" ]] || fail "could not resolve the signing certificate name"

    certificate_subject="$(
        security find-certificate -c "$certificate_name" -p 2>/dev/null |
            openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true
    )"
    signing_team_id="$(sed -n 's/.*OU=\([^,]*\).*/\1/p' <<< "$certificate_subject")"
fi
[[ "$signing_team_id" =~ ^[[:alnum:]]{10}$ ]] || \
    fail "could not resolve the signing certificate Team ID"

is_developer_id=false
if [[ "$identity_line" == *"Developer ID Application:"* ]]; then
    is_developer_id=true
fi

if [[ "$use_timestamp" == false && "$identity_line" == *"Developer ID Application"* ]]; then
    fail "Developer ID Application signatures require a secure timestamp"
fi

timestamp_arguments=(--timestamp)
if [[ "$use_timestamp" == false ]]; then
    timestamp_arguments=(--timestamp=none)
fi

sign_target() {
    local target="$1"
    codesign \
        --force \
        --sign "$identity" \
        --options runtime \
        "${timestamp_arguments[@]}" \
        "$target"
}

resolved_entitlements_file=""
resolved_provisioning_profile=""
decoded_profile_file=""
decoded_profile_plist=""
profile_certificate_file=""
app_bundle_identifier=""

cleanup() {
    local temporary_file
    for temporary_file in \
        "$resolved_entitlements_file" \
        "$decoded_profile_file" \
        "$decoded_profile_plist" \
        "$profile_certificate_file"; do
        if [[ -n "$temporary_file" ]]; then
            rm -f "$temporary_file"
        fi
    done
}
trap cleanup EXIT

resolve_app_entitlements() {
    local target="$1"
    local source_entitlements="$repository_root/Configuration/Nativ.entitlements"
    local info_plist="$target/Contents/Info.plist"

    [[ -f "$source_entitlements" ]] || fail "app entitlements are missing: $source_entitlements"
    [[ -f "$info_plist" ]] || fail "app Info.plist is missing: $info_plist"

    app_bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
    [[ -n "$app_bundle_identifier" ]] || fail "app bundle identifier is missing"

    resolved_entitlements_file="$(mktemp "${TMPDIR:-/tmp}/nativ-entitlements.XXXXXX.plist")"
    cp "$source_entitlements" "$resolved_entitlements_file"

    if [[ "$is_developer_id" == true || -n "$provisioning_profile" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Set :keychain-access-groups:0 $signing_team_id.$app_bundle_identifier" \
            "$resolved_entitlements_file"
        /usr/libexec/PlistBuddy \
            -c "Add :com.apple.application-identifier string $signing_team_id.$app_bundle_identifier" \
            -c "Add :com.apple.developer.team-identifier string $signing_team_id" \
            "$resolved_entitlements_file"
    else
        # A profile-less Apple Development signature cannot claim a restricted
        # keychain sharing group. Nativ's local Keychain queries do not request
        # an access group, so use the normal macOS Keychain behavior instead.
        /usr/libexec/PlistBuddy \
            -c "Delete :keychain-access-groups" \
            "$resolved_entitlements_file"
    fi

    if grep -q '\$(' "$resolved_entitlements_file"; then
        fail "app entitlements still contain unresolved Xcode build settings"
    fi
    plutil -lint "$resolved_entitlements_file" >/dev/null
}

prepare_provisioning_profile() {
    local target="$1"
    local encoded_profile="$repository_root/Configuration/Nativ_Developer_ID.provisionprofile.base64"

    if [[ -n "$provisioning_profile" ]]; then
        case "$provisioning_profile" in
            /*) resolved_provisioning_profile="$provisioning_profile" ;;
            *) resolved_provisioning_profile="$PWD/$provisioning_profile" ;;
        esac
        [[ -f "$resolved_provisioning_profile" ]] || \
            fail "provisioning profile not found: $resolved_provisioning_profile"
    elif [[ "$is_developer_id" == true ]]; then
        [[ -f "$encoded_profile" ]] || \
            fail "encoded Developer ID provisioning profile is missing: $encoded_profile"
        decoded_profile_file="$(
            mktemp "${TMPDIR:-/tmp}/nativ-developer-id.XXXXXX.provisionprofile"
        )"
        /usr/bin/base64 -D -i "$encoded_profile" -o "$decoded_profile_file" || \
            fail "could not decode the Developer ID provisioning profile"
        resolved_provisioning_profile="$decoded_profile_file"
    else
        # Apple Development signatures do not require an embedded Developer ID
        # provisioning profile. Return success explicitly: a bare `return`
        # inherits the failed `is_developer_id` test above, and `set -e` would
        # abort before the app is signed with its entitlements.
        return 0
    fi

    decoded_profile_plist="$(mktemp "${TMPDIR:-/tmp}/nativ-profile.XXXXXX.plist")"
    security cms -D -i "$resolved_provisioning_profile" > "$decoded_profile_plist" || \
        fail "could not validate the provisioning profile signature"

    local profile_name
    local profile_team_id
    local profile_entitlement_team_id
    local profile_application_identifier
    local profile_platform
    local provisions_all_devices
    profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded_profile_plist")"
    profile_team_id="$(
        /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile_plist"
    )"
    profile_entitlement_team_id="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.developer.team-identifier' \
            "$decoded_profile_plist"
    )"
    profile_application_identifier="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.application-identifier' \
            "$decoded_profile_plist"
    )"
    profile_platform="$(
        /usr/libexec/PlistBuddy -c 'Print :Platform:0' "$decoded_profile_plist"
    )"
    provisions_all_devices="$(
        /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$decoded_profile_plist"
    )"

    local expected_application_identifier="$signing_team_id.$app_bundle_identifier"
    [[ "$profile_team_id" == "$signing_team_id" ]] || \
        fail "profile $profile_name belongs to Team $profile_team_id, expected $signing_team_id"
    [[ "$profile_entitlement_team_id" == "$signing_team_id" ]] || \
        fail "profile $profile_name does not authorize Team $signing_team_id"
    [[ "$profile_application_identifier" == "$expected_application_identifier" ]] || \
        fail "profile $profile_name authorizes $profile_application_identifier, expected $expected_application_identifier"
    [[ "$profile_platform" == "OSX" && "$provisions_all_devices" == "true" ]] || \
        fail "profile $profile_name is not a Developer ID distribution profile"

    local expected_keychain_group="$expected_application_identifier"
    local profile_keychain_group
    local keychain_group_index=0
    local authorizes_keychain_group=false
    while profile_keychain_group="$(
        /usr/libexec/PlistBuddy \
            -c "Print :Entitlements:keychain-access-groups:$keychain_group_index" \
            "$decoded_profile_plist" 2>/dev/null
    )"; do
        if [[ "$profile_keychain_group" == "$expected_keychain_group" || \
              "$profile_keychain_group" == "$signing_team_id.*" ]]; then
            authorizes_keychain_group=true
            break
        fi
        ((keychain_group_index += 1))
    done
    [[ "$authorizes_keychain_group" == true ]] || \
        fail "profile $profile_name does not authorize Keychain group $expected_keychain_group"

    command -v openssl >/dev/null 2>&1 || \
        fail "openssl is required to validate the provisioning profile certificate"
    profile_certificate_file="$(mktemp "${TMPDIR:-/tmp}/nativ-profile-cert.XXXXXX.cer")"
    local certificate_index=0
    local profile_certificate_hash
    local authorizes_signing_identity=false
    while /usr/libexec/PlistBuddy \
        -c "Print :DeveloperCertificates:$certificate_index" \
        "$decoded_profile_plist" > "$profile_certificate_file" 2>/dev/null; do
        profile_certificate_hash="$(
            openssl x509 -inform DER -in "$profile_certificate_file" \
                -noout -fingerprint -sha1 2>/dev/null |
                sed 's/.*=//' |
                tr -d ':' |
                tr '[:lower:]' '[:upper:]'
        )"
        if [[ "$profile_certificate_hash" == "$signing_identity_hash" ]]; then
            authorizes_signing_identity=true
            break
        fi
        ((certificate_index += 1))
    done
    [[ "$authorizes_signing_identity" == true ]] || \
        fail "profile $profile_name does not contain the selected signing certificate"

    cp "$resolved_provisioning_profile" "$target/Contents/embedded.provisionprofile"
    chmod 644 "$target/Contents/embedded.provisionprofile"
    echo "Embedded provisioning profile: $profile_name"
}

sign_app() {
    local target="$1"
    resolve_app_entitlements "$target"
    prepare_provisioning_profile "$target"
    codesign \
        --force \
        --sign "$identity" \
        --options runtime \
        --entitlements "$resolved_entitlements_file" \
        "${timestamp_arguments[@]}" \
        "$target"
}

if [[ "$is_disk_image" == true ]]; then
    echo "Signing disk image with: $identity"
    codesign \
        --force \
        --sign "$identity" \
        "${timestamp_arguments[@]}" \
        "$target_path"
    codesign --verify --strict --verbose=2 "$target_path"

    disk_image_signature="$(codesign -dvvv "$target_path" 2>&1)"
    if [[ "$use_timestamp" == true ]]; then
        [[ "$disk_image_signature" == *"Authority=Developer ID Application:"* ]] || \
            fail "disk image is not signed with a Developer ID Application certificate"
        [[ "$disk_image_signature" == *"Timestamp="* ]] || \
            fail "disk image signature does not contain a secure timestamp"
    fi

    echo "Signed and verified: $target_path"
    exit 0
fi

native_files=()
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    if [[ "$file_type" == Mach-O* ]]; then
        native_files+=("$candidate")
    fi
done < <(find "$app_path" -type f -print0)

echo "Signing ${#native_files[@]} Mach-O files with: $identity"
for native_file in "${native_files[@]}"; do
    sign_target "$native_file"
done

# Re-seal nested code bundles after their contents have been modified. `find
# -depth` guarantees that nested bundles are handled before their containers.
while IFS= read -r -d '' code_bundle; do
    sign_target "$code_bundle"
done < <(
    find "$app_path" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \) \
        ! -path "$app_path" \
        -print0
)

# Preserve the production entitlements while intentionally omitting
# development-only entitlements such as com.apple.security.get-task-allow.
sign_app "$app_path"

for native_file in "${native_files[@]}"; do
    codesign --verify --strict "$native_file"
done
codesign --verify --deep --strict --verbose=2 "$app_path"

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
if [[ "$app_entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    fail "the signed app still contains the development-only get-task-allow entitlement"
fi
if [[ "$app_entitlements" != *"com.apple.security.device.audio-input"* ]]; then
    fail "the signed app is missing the audio-input entitlement"
fi
if [[ ("$is_developer_id" == true || -n "$provisioning_profile") && \
      "$app_entitlements" != *"keychain-access-groups"* ]]; then
    fail "the signed app is missing its keychain access group"
fi
if [[ "$is_developer_id" == true ]]; then
    [[ -f "$app_path/Contents/embedded.provisionprofile" ]] || \
        fail "the signed app is missing its embedded provisioning profile"
    if [[ "$app_entitlements" != *"com.apple.application-identifier"* || \
          "$app_entitlements" != *"com.apple.developer.team-identifier"* ]]; then
        fail "the signed app is missing its profile-backed identity entitlements"
    fi
fi

echo "Signed and verified: $app_path"
