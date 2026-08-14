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

case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        readonly platform="Darwin"
        readonly architecture="arm64"
        readonly expected_checksum="cd38785573052942c337805ea365bbc27718e0bd254ee4a48e668a76b3f4a1ce"
        ;;
    Darwin:x86_64)
        readonly platform="Darwin"
        readonly architecture="x86_64"
        readonly expected_checksum="7a6395a29752b3ad771bfb9d66fd1bfcb088fcbdfeb65fc22cb1146b67a3621a"
        ;;
    Linux:aarch64|Linux:arm64)
        readonly platform="Linux"
        readonly architecture="arm64"
        readonly expected_checksum="11e14ce34492b6a07ae4bc567d8773fc4cd3dd77e91daf3f9cacc88b15d840ea"
        ;;
    Linux:x86_64)
        readonly platform="Linux"
        readonly architecture="x86_64"
        readonly expected_checksum="cbf38bd3364518ccf80b6a25587d5ef11655b15d63cbb48bc066384d0b5b5964"
        ;;
    *)
        fail "GitHub MCP Server is not packaged for $(uname -s) $(uname -m)"
        ;;
esac

readonly archive_name="github-mcp-server_${platform}_${architecture}.tar.gz"
readonly download_url="https://github.com/github/github-mcp-server/releases/download/v${version}/${archive_name}"
readonly output_directory="$1"
readonly cache_directory="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/nativ-derived}/github-mcp-server/${version}/${platform}_${architecture}"
readonly archive_path="${cache_directory}/${archive_name}"
readonly extracted_directory="${cache_directory}/extracted"
readonly cached_executable="${extracted_directory}/github-mcp-server"

archive_checksum() {
    if [[ "$platform" == "Darwin" ]]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

mkdir -p "$cache_directory"

archive_is_valid=false
if [[ -f "$archive_path" ]]; then
    actual_checksum="$(archive_checksum "$archive_path")"
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
    actual_checksum="$(archive_checksum "$temporary_archive")"
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
