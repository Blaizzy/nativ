#!/bin/bash

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

if (($# != 1)); then
    fail "usage: install_github_mcp_server.sh OUTPUT_DIRECTORY"
fi

readonly version="1.9.0"
readonly expected_checksum="cd38785573052942c337805ea365bbc27718e0bd254ee4a48e668a76b3f4a1ce"
readonly archive_name="github-mcp-server_Darwin_arm64.tar.gz"
readonly download_url="https://github.com/github/github-mcp-server/releases/download/v${version}/${archive_name}"
readonly output_directory="$1"
readonly cache_directory="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/nativ-derived}/github-mcp-server/${version}"
readonly archive_path="${cache_directory}/${archive_name}"
readonly extracted_directory="${cache_directory}/extracted"
readonly cached_executable="${extracted_directory}/github-mcp-server"

[[ "$(uname -m)" == "arm64" ]] || fail "GitHub MCP Server is currently packaged for arm64 only"

mkdir -p "$cache_directory"

archive_is_valid=false
if [[ -f "$archive_path" ]]; then
    actual_checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    [[ "$actual_checksum" == "$expected_checksum" ]] && archive_is_valid=true
fi

if [[ "$archive_is_valid" != true ]]; then
    temporary_archive="${archive_path}.download"
    curl \
        --fail \
        --location \
        --retry 3 \
        --silent \
        --show-error \
        --output "$temporary_archive" \
        "$download_url"
    actual_checksum="$(shasum -a 256 "$temporary_archive" | awk '{print $1}')"
    [[ "$actual_checksum" == "$expected_checksum" ]] || \
        fail "GitHub MCP Server checksum mismatch"
    mv "$temporary_archive" "$archive_path"
fi

if [[ ! -x "$cached_executable" ]]; then
    mkdir -p "$extracted_directory"
    tar -xzf "$archive_path" -C "$extracted_directory"
    [[ -x "$cached_executable" ]] || fail "GitHub MCP Server archive did not contain its executable"
    [[ -f "${extracted_directory}/LICENSE" ]] || fail "GitHub MCP Server archive did not contain its license"
fi

mkdir -p "$output_directory"
install -m 755 "$cached_executable" "$output_directory/github-mcp-server"
install -m 644 "${extracted_directory}/LICENSE" "$output_directory/github-mcp-server-LICENSE.txt"

echo "Installed GitHub MCP Server v${version} with OAuth support"
