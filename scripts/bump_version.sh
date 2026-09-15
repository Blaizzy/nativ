#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bump_version.sh [VERSION]

Increments the patch version and build number in project.yml, then regenerates
the Xcode project with xcodegen. Pass VERSION to set an explicit stable or RC
version instead (a leading "v" is accepted); the build number is still
incremented. RC labels are stored separately from the numeric marketing version.
Without VERSION, the next stable patch version is selected, even from an RC.

Examples:
  ./scripts/bump_version.sh          # 0.3.9 -> 0.3.10
  ./scripts/bump_version.sh 0.4.0    # set version to 0.4.0
  ./scripts/bump_version.sh v1.0.0   # set version to 1.0.0
  ./scripts/bump_version.sh v0.4.0rc1 # set release label to 0.4.0rc1, marketing version to 0.4.0
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
project_file="$repository_root/project.yml"

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

(($# <= 1)) || {
    usage >&2
    exit 2
}

[[ -f "$project_file" ]] || fail "project.yml not found at $project_file"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

marketing_setting_count="$(awk '$1 == "MARKETING_VERSION:" { count++ } END { print count + 0 }' "$project_file")"
build_setting_count="$(awk '$1 == "CURRENT_PROJECT_VERSION:" { count++ } END { print count + 0 }' "$project_file")"
release_setting_count="$(awk '$1 == "NATIV_RELEASE_VERSION:" { count++ } END { print count + 0 }' "$project_file")"
((marketing_setting_count > 0)) || fail "project.yml does not contain MARKETING_VERSION"
((build_setting_count > 0)) || fail "project.yml does not contain CURRENT_PROJECT_VERSION"
((release_setting_count > 0)) || fail "project.yml does not contain NATIV_RELEASE_VERSION"

marketing_versions="$(awk '$1 == "MARKETING_VERSION:" { print $2 }' "$project_file" | sort -u)"
build_numbers="$(awk '$1 == "CURRENT_PROJECT_VERSION:" { print $2 }' "$project_file" | sort -u)"
marketing_version_count="$(printf '%s\n' "$marketing_versions" | awk 'NF { count++ } END { print count + 0 }')"
build_number_count="$(printf '%s\n' "$build_numbers" | awk 'NF { count++ } END { print count + 0 }')"

((marketing_version_count == 1)) || fail "MARKETING_VERSION values in project.yml do not agree"
((build_number_count == 1)) || fail "CURRENT_PROJECT_VERSION values in project.yml do not agree"

current_version="$marketing_versions"
current_build_number="$build_numbers"
[[ "$current_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
    fail "current MARKETING_VERSION must use MAJOR.MINOR.PATCH format: $current_version"
[[ "$current_build_number" =~ ^[1-9][0-9]*$ ]] || \
    fail "current CURRENT_PROJECT_VERSION must be a positive integer: $current_build_number"

if (($# == 1)); then
    next_version="${1#v}"
else
    IFS=. read -r version_major version_minor version_patch <<< "$current_version"
    next_version="${version_major}.${version_minor}.$((10#$version_patch + 1))"
fi
version_metadata="$(python3 "$script_directory/macos_release.py" version "$next_version")" || fail "invalid version: $next_version"
read -r next_version next_marketing_version next_channel next_tag <<< "$version_metadata"
[[ "$next_marketing_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
    fail "version must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCHrcN format: $next_version"
next_release_setting='$(MARKETING_VERSION)'
if [[ "$next_channel" == rc ]]; then
    next_release_setting="$next_version"
fi
next_build_number="$((10#$current_build_number + 1))"

temporary_project="$(mktemp "${project_file}.tmp.XXXXXX")"
trap 'rm -f "$temporary_project"' EXIT
cp -p "$project_file" "$temporary_project"

awk \
    -v version="$next_marketing_version" \
    -v release_version="$next_release_setting" \
    -v build_number="$next_build_number" \
    '
        $1 == "MARKETING_VERSION:" {
            sub(/MARKETING_VERSION:[[:space:]]*[^[:space:]#]+/, "MARKETING_VERSION: " version)
        }
        $1 == "CURRENT_PROJECT_VERSION:" {
            sub(/CURRENT_PROJECT_VERSION:[[:space:]]*[^[:space:]#]+/, "CURRENT_PROJECT_VERSION: " build_number)
        }
        $1 == "NATIV_RELEASE_VERSION:" {
            sub(/NATIV_RELEASE_VERSION:[[:space:]]*[^[:space:]#]+/, "NATIV_RELEASE_VERSION: " release_version)
        }
        { print }
    ' "$project_file" > "$temporary_project"

mv "$temporary_project" "$project_file"

echo "Bumped Nativ from $current_version ($current_build_number) to $next_version ($next_build_number)."
echo "Regenerating Nativ.xcodeproj..."
(
    cd "$repository_root"
    xcodegen generate
)

echo "Updated project.yml and Nativ.xcodeproj."
