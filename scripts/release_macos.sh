#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: release_macos.sh [options] VERSION

Builds and Developer ID signs Nativ, packages it in a signed disk image,
notarizes and staples the DMG, then generates its signed Sparkle appcast.
VERSION may optionally start with "v" and end in rcN (for example v0.4.0rc1).

Options:
  --build-number NUMBER CFBundleVersion. Defaults to a UTC timestamp.
  --release-notes PATH  Release notes to embed in the Sparkle feed.
  --output-dir PATH     Output directory. Defaults to dist/release.
  --archive-path PATH   Output xcarchive path. Defaults to dist/archive/.
  --identity ID         Developer ID Application identity name or SHA-1 hash.
  --team-id ID          Resolve the Developer ID identity from a Team ID.
  --keychain-profile NAME
                        notarytool profile (local default is
                        mlx-vlm-server-notary).
  -h, --help            Show this help.

App Store Connect API-key authentication can be supplied through
NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER. CI supplies the Sparkle key
through SPARKLE_PRIVATE_KEY; local runs use the Marvis-Labs Keychain account.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
build_number=""
release_notes=""
output_directory="dist/release"
archive_path=""
identity=""
team_id=""
keychain_profile=""

while (($# > 0)); do
    case "$1" in
        --build-number)
            (($# >= 2)) || fail "--build-number requires a value"
            build_number="$2"
            shift 2
            ;;
        --release-notes)
            (($# >= 2)) || fail "--release-notes requires a value"
            release_notes="$2"
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || fail "--output-dir requires a value"
            output_directory="$2"
            shift 2
            ;;
        --archive-path)
            (($# >= 2)) || fail "--archive-path requires a value"
            archive_path="$2"
            shift 2
            ;;
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
        --keychain-profile)
            (($# >= 2)) || fail "--keychain-profile requires a value"
            keychain_profile="$2"
            shift 2
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

version_metadata="$(python3 "$script_directory/macos_release.py" version "$1")" || fail "invalid version: $1"
read -r version marketing_version release_channel release_tag <<< "$version_metadata"
if [[ -z "$build_number" ]]; then
    build_number="$(date -u +%Y%m%d%H%M)"
fi
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "build number must be a positive integer"
[[ -z "$identity" || -z "$team_id" ]] || fail "use either --identity or --team-id, not both"
if [[ -n "$release_notes" ]]; then
    [[ -f "$release_notes" ]] || fail "release notes not found: $release_notes"
fi

case "$output_directory" in /*) ;; *) output_directory="$repository_root/$output_directory" ;; esac
if [[ -z "$archive_path" ]]; then
    archive_path="$repository_root/dist/archive/Nativ-${version}-${build_number}.xcarchive"
else
    case "$archive_path" in /*) ;; *) archive_path="$repository_root/$archive_path" ;; esac
fi

release_dmg="$output_directory/Nativ-${version}.dmg"
appcast_path="$output_directory/appcast.xml"
[[ ! -e "$archive_path" ]] || fail "archive already exists: $archive_path"
[[ ! -e "$release_dmg" ]] || fail "release DMG already exists: $release_dmg"
mkdir -p "$output_directory"

archive_arguments=(
    --archive-path "$archive_path"
    --marketing-version "$marketing_version"
    --release-version "$version"
    --build-number "$build_number"
    --sign
)
if [[ -n "$identity" ]]; then
    archive_arguments+=(--identity "$identity")
elif [[ -n "$team_id" ]]; then
    archive_arguments+=(--team-id "$team_id")
fi

echo "Building Nativ $version ($build_number)..."
"$script_directory/archive_macos_release.sh" "${archive_arguments[@]}"

app_path="$archive_path/Products/Applications/Nativ.app"
packaging_arguments=(--output "$release_dmg")
if [[ -n "$identity" ]]; then
    packaging_arguments+=(--identity "$identity")
elif [[ -n "$team_id" ]]; then
    packaging_arguments+=(--team-id "$team_id")
fi
"$script_directory/package_macos_dmg.sh" "${packaging_arguments[@]}" "$app_path"

notarization_arguments=()
if [[ -n "$keychain_profile" ]]; then
    notarization_arguments+=(--keychain-profile "$keychain_profile")
fi
if ((${#notarization_arguments[@]} > 0)); then
    "$script_directory/notarize_macos_release.sh" "${notarization_arguments[@]}" "$release_dmg"
else
    "$script_directory/notarize_macos_release.sh" "$release_dmg"
fi

appcast_arguments=(--output "$appcast_path" --tag "$release_tag")
if [[ -n "$release_notes" ]]; then
    appcast_arguments+=(--release-notes "$release_notes")
fi
"$script_directory/generate_macos_appcast.sh" "${appcast_arguments[@]}" "$release_dmg"

echo
echo "Release is ready to publish:"
echo "  Asset:   $release_dmg"
echo "  Appcast: $appcast_path"
