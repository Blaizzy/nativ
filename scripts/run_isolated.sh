#!/bin/bash
#
# Launches a locally built Nativ against its own home directory.
#
# Nativ resolves ~/Library/Application Support/Nativ for settings, chats,
# analytics, traces, artifacts, and routines. A dev build therefore shares all
# of that with an installed copy, and running one can change the other's state.
# Twenty-odd call sites resolve that path, so overriding HOME for the launch
# isolates every one of them without touching product code.
#
# The Hugging Face cache is symlinked rather than copied — it is measured in
# terabytes, and a sandboxed home with no models is not worth launching.
#
#   scripts/run_isolated.sh [/path/to/App.app]

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

derived="${XCODE_DERIVED_DATA:-build/NativDevelopmentDerivedData}"
product="${NATIV_PRODUCT_NAME:-$(
    sed -n 's/^NATIV_PRODUCT_NAME[[:space:]]*=[[:space:]]*//p' \
        Configuration/Signing.local.xcconfig Configuration/Signing.xcconfig 2>/dev/null | head -1
)}"
product="${product:-Nativ}"
app_path="${1:-$derived/Build/Products/Debug/$product.app}"

[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"

executable_name="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$app_path/Contents/Info.plist" 2>/dev/null || true
)"
[[ -n "$executable_name" ]] || executable_name="$(basename "$app_path" .app)"
executable="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable" ]] || fail "no executable at $executable"

sandbox="${NATIV_SANDBOX_HOME:-$HOME/.nativ-sandboxes/$executable_name}"
mkdir -p "$sandbox/Library/Application Support" "$sandbox/Library/Caches" "$sandbox/.cache"

# Share the model cache; isolate everything else.
if [[ -d "$HOME/.cache/huggingface" && ! -e "$sandbox/.cache/huggingface" ]]; then
    ln -s "$HOME/.cache/huggingface" "$sandbox/.cache/huggingface"
fi

echo "app     $app_path"
echo "home    $sandbox"
echo "state   $sandbox/Library/Application Support/Nativ"
echo "models  shared from $HOME/.cache/huggingface"
echo

# Directly, not via `open`: launchd would not carry the overridden HOME.
HOME="$sandbox" exec "$executable" "$@"
