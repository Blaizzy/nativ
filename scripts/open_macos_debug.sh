#!/bin/bash

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

if (($# != 1)); then
    fail "usage: open_macos_debug.sh /path/to/Nativ.app"
fi

app_path="$1"
[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"
app_path="$(cd "$(dirname "$app_path")" && pwd -P)/$(basename "$app_path")"

bundle_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$app_path/Contents/Info.plist" 2>/dev/null || true
)"
[[ -n "$bundle_identifier" ]] || fail "Nativ has no bundle identifier"

codesign --verify --deep --strict "$app_path"
signature_details="$(codesign -dvvv -r- "$app_path" 2>&1)"
[[ "$signature_details" == *"Authority=Apple Development:"* ]] || {
    fail "refusing to open an ad-hoc build because it would invalidate macOS permissions"
}
[[ "$signature_details" == *"TeamIdentifier="* ]] || {
    fail "refusing to open a build without a signing Team ID"
}
[[ "$signature_details" == *"anchor apple generic"* ]] || {
    fail "refusing to open a build without a stable designated requirement"
}

# Multiple Nativ builds compete for the same global shortcuts and make privacy
# status appear inconsistent. Close prior instances before opening this exact
# verified bundle.
while IFS= read -r process_id; do
    [[ -n "$process_id" ]] || continue
    kill "$process_id" 2>/dev/null || true
done < <(pgrep -x Nativ || true)

open -na "$app_path"

expected_command="$app_path/Contents/MacOS/Nativ"
for _ in {1..20}; do
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] || continue
        process_command="$(ps -p "$process_id" -o command= 2>/dev/null || true)"
        process_command="${process_command#"${process_command%%[![:space:]]*}"}"
        if [[ "$process_command" == "$expected_command" ]]; then
            echo "Opened $app_path"
            echo "Bundle identifier: $bundle_identifier"
            exit 0
        fi
    done < <(pgrep -x Nativ || true)
    sleep 0.25
done

fail "Nativ did not remain running after launch"
