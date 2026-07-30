#!/bin/bash

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

if (($# != 1)); then
    fail "usage: sign_macos_debug.sh /path/to/Nativ.app"
fi

app_path="$1"
[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"

script_directory="$(cd "$(dirname "$0")" && pwd -P)"

# Accessibility and the other macOS privacy services identify an app through
# its designated code-signing requirement. Ad-hoc signatures are tied to one
# build, so use the developer's Apple Development identity even for a local
# unsigned Xcode product.
if ! "$script_directory/sign_macos_release.sh" --no-timestamp "$app_path"; then
    cat >&2 <<'EOF'

The local Apple Development identity could not sign Nativ. Make sure the
login keychain containing its private key is unlocked, then build again.
EOF
    exit 1
fi

signature_details="$(codesign -dvvv -r- "$app_path" 2>&1)"
[[ "$signature_details" == *"Authority=Apple Development:"* ]] || {
    fail "debug app is not signed with an Apple Development identity"
}
[[ "$signature_details" == *"TeamIdentifier="* ]] || {
    fail "debug app signature does not contain a Team ID"
}
[[ "$signature_details" == *"anchor apple generic"* ]] || {
    fail "debug app does not have a signer-bound designated requirement"
}

echo "Signed $app_path with a stable Apple Development identity"
