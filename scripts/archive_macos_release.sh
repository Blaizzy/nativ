#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: archive_macos_release.sh [options]

Generates the Xcode project and creates an unsigned Release xcarchive whose
app can be signed from the inside out with sign_macos_release.sh.

Options:
  --archive-path PATH   Output xcarchive. Defaults to a timestamped archive
                        under dist/archive/.
  --derived-data PATH   DerivedData directory. Defaults to
                        build/XcodeDerivedData.
  --marketing-version VERSION
                        CFBundleShortVersionString for this archive.
  --build-number NUMBER CFBundleVersion for this archive.
  --release-version VERSION
                        Public release label, including an optional rcN suffix.
  --skip-generate       Do not run xcodegen before archiving.
  --sign                Sign after archiving, inferring DEVELOPMENT_TEAM from
                        the Release build settings.
  --identity ID         Sign the archived app after building it.
  --team-id ID          Sign using a certificate resolved from this Team ID.
  --no-timestamp        Pass --no-timestamp to the signing script. Intended
                        only for local Apple Development signing.
  -h, --help            Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
archive_path=""
derived_data_path="${NATIV_DERIVED_DATA:-build/XcodeDerivedData}"
generate_project=true
sign_archive=false
identity=""
team_id=""
no_timestamp=false
marketing_version=""
release_version=""
build_number=""

while (($# > 0)); do
    case "$1" in
        --archive-path)
            (($# >= 2)) || fail "--archive-path requires a value"
            archive_path="$2"
            shift 2
            ;;
        --derived-data)
            (($# >= 2)) || fail "--derived-data requires a value"
            derived_data_path="$2"
            shift 2
            ;;
        --marketing-version)
            (($# >= 2)) || fail "--marketing-version requires a value"
            marketing_version="$2"
            shift 2
            ;;
        --build-number)
            (($# >= 2)) || fail "--build-number requires a value"
            build_number="$2"
            shift 2
            ;;
        --release-version)
            (($# >= 2)) || fail "--release-version requires a value"
            release_version="$2"
            shift 2
            ;;
        --skip-generate)
            generate_project=false
            shift
            ;;
        --sign)
            sign_archive=true
            shift
            ;;
        --identity)
            (($# >= 2)) || fail "--identity requires a value"
            sign_archive=true
            identity="$2"
            shift 2
            ;;
        --team-id)
            (($# >= 2)) || fail "--team-id requires a value"
            sign_archive=true
            team_id="$2"
            shift 2
            ;;
        --no-timestamp)
            no_timestamp=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if [[ -n "$identity" && -n "$team_id" ]]; then
    fail "use either --identity or --team-id, not both"
fi
if [[ "$no_timestamp" == true && "$sign_archive" == false ]]; then
    fail "--no-timestamp requires --sign, --team-id, or --identity"
fi
if [[ -n "$marketing_version" && ! "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
    fail "invalid marketing version: $marketing_version"
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    fail "build number must be a positive integer: $build_number"
fi
if [[ -n "$release_version" ]]; then
    metadata="$(python3 "$script_directory/macos_release.py" version "$release_version")" || fail "invalid release version"
    read -r release_version release_marketing_version release_channel release_tag <<< "$metadata"
    [[ -z "$marketing_version" || "$marketing_version" == "$release_marketing_version" ]] || fail "release and marketing versions disagree"
    marketing_version="$release_marketing_version"
fi

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
if [[ "$generate_project" == true ]]; then
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required (or pass --skip-generate)"
fi

if [[ -z "$archive_path" ]]; then
    archive_path="dist/archive/Nativ-$(date +%Y%m%d-%H%M%S).xcarchive"
fi

case "$archive_path" in
    /*) ;;
    *) archive_path="$repository_root/$archive_path" ;;
esac
case "$derived_data_path" in
    /*) ;;
    *) derived_data_path="$repository_root/$derived_data_path" ;;
esac

[[ "$archive_path" == *.xcarchive ]] || fail "--archive-path must end in .xcarchive"
[[ ! -e "$archive_path" ]] || fail "archive already exists: $archive_path"
mkdir -p "$(dirname "$archive_path")" "$derived_data_path"

cd "$repository_root"
if [[ "$generate_project" == true ]]; then
    echo "Generating Nativ.xcodeproj..."
    xcodegen generate
fi

echo "Building unsigned Release archive..."
xcodebuild_arguments=(
    -project Nativ.xcodeproj
    -scheme Nativ
    -configuration Release
    -derivedDataPath "$derived_data_path"
    -archivePath "$archive_path"
    CODE_SIGNING_ALLOWED=NO
)
if [[ -n "$marketing_version" ]]; then
    xcodebuild_arguments+=(MARKETING_VERSION="$marketing_version")
fi
if [[ -n "$build_number" ]]; then
    xcodebuild_arguments+=(CURRENT_PROJECT_VERSION="$build_number")
fi
if [[ -n "$release_version" ]]; then
    xcodebuild_arguments+=(NATIV_RELEASE_VERSION="$release_version")
fi
xcodebuild \
    "${xcodebuild_arguments[@]}" \
    archive

archive_info="$archive_path/Info.plist"
[[ -f "$archive_info" ]] || fail "archive metadata is missing: $archive_info"
application_path="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_info" 2>/dev/null || true)"
[[ -n "$application_path" ]] || fail "archive is not classified as a macOS app archive"

app_path="$archive_path/Products/$application_path"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    fail "archived app is missing: $app_path"
[[ ! -e "$archive_path/Products/Library/Frameworks/NativServerKit.framework" ]] || \
    fail "NativServerKit was installed as a top-level archive product; check SKIP_INSTALL"

archived_marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
archived_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
if [[ -n "$marketing_version" && "$archived_marketing_version" != "$marketing_version" ]]; then
    fail "archived marketing version is $archived_marketing_version, expected $marketing_version"
fi
if [[ -n "$build_number" && "$archived_build_number" != "$build_number" ]]; then
    fail "archived build number is $archived_build_number, expected $build_number"
fi
if [[ -n "$release_version" ]]; then
    archived_release_version="$(/usr/libexec/PlistBuddy -c 'Print :NativReleaseVersion' "$app_path/Contents/Info.plist")"
    [[ "$archived_release_version" == "$release_version" ]] || fail "archived release version is $archived_release_version, expected $release_version"
fi

if [[ "$sign_archive" == true ]]; then
    signing_arguments=()
    if [[ -n "$identity" ]]; then
        signing_arguments+=(--identity "$identity")
    elif [[ -n "$team_id" ]]; then
        signing_arguments+=(--team-id "$team_id")
    fi
    if [[ "$no_timestamp" == true ]]; then
        signing_arguments+=(--no-timestamp)
    fi
    if ((${#signing_arguments[@]} > 0)); then
        "$script_directory/sign_macos_release.sh" "${signing_arguments[@]}" "$app_path"
    else
        "$script_directory/sign_macos_release.sh" "$app_path"
    fi
fi

echo
echo "Archive: $archive_path"
echo "App:     $app_path"
echo "Version: $archived_marketing_version ($archived_build_number)"
if [[ "$sign_archive" == false ]]; then
    echo
    echo "Next, sign the archived app:"
    printf '  %q %q\n' "$script_directory/sign_macos_release.sh" "$app_path"
fi
