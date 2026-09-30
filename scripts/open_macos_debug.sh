#!/bin/bash

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

replace_existing=false
if [[ "${1:-}" == "--replace-existing" ]]; then
    replace_existing=true
    shift
fi
if (($# != 1)); then
    fail "usage: open_macos_debug.sh [--replace-existing] /path/to/Nativ.app"
fi

app_path="$1"
[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"
app_path="$(cd "$app_path" && pwd -P)"

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

# All worktrees share the app's identity, data, server port, and shortcuts. Serialize
# launches, and require an intentional switch before stopping another checkout.
launch_directory="$(getconf DARWIN_USER_TEMP_DIR)"
[[ -d "$launch_directory" ]] || fail "the per-user temporary directory is unavailable"
launch_lock="${launch_directory%/}/nativ-debug-launch.lock"
umask 077
shlock -f "$launch_lock" -p "$$" || fail "another Nativ launch is in progress; try again when it finishes"
trap 'rm -f "$launch_lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expected_command="$app_path/Contents/MacOS/Nativ"
process_command() {
    local value
    value="$(ps -p "$1" -o comm= 2>/dev/null || true)"
    printf '%s\n' "${value#"${value%%[![:space:]]*}"}"
}

process_ids=()
process_commands=()
foreign_commands=()
while IFS= read -r process_id; do
    [[ -n "$process_id" ]] || continue
    process_path="$(process_command "$process_id")"
    [[ -n "$process_path" ]] || continue
    process_ids+=("$process_id")
    process_commands+=("$process_path")
    if [[ "$process_path" != "$expected_command" ]]; then
        foreign_commands+=("$process_path")
    fi
done < <(pgrep -u "$UID" -x Nativ || true)

# Preflight every process before stopping any, including this checkout's own app.
if ((${#foreign_commands[@]} > 0)) && [[ "$replace_existing" != true ]]; then
    printf 'A different Nativ build is already running:\n' >&2
    printf '  %s\n' "${foreign_commands[@]}" >&2
    fail "left all running builds untouched. Quit the other build, or use --replace-existing to switch intentionally"
fi

for ((index = 0; index < ${#process_ids[@]}; index++)); do
    process_id="${process_ids[$index]}"
    process_path="${process_commands[$index]}"
    # Recheck the executable in case the process exited and its PID was reused.
    [[ "$(process_command "$process_id")" == "$process_path" ]] || continue
    echo "Stopping $process_path (PID $process_id)"
    kill "$process_id" 2>/dev/null || true
done

# Let the previous app release its server and shortcuts before starting the next.
for ((index = 0; index < ${#process_ids[@]}; index++)); do
    process_id="${process_ids[$index]}"
    process_path="${process_commands[$index]}"
    for _ in {1..40}; do
        [[ "$(process_command "$process_id")" == "$process_path" ]] || break
        sleep 0.25
    done
    [[ "$(process_command "$process_id")" != "$process_path" ]] || {
        fail "Nativ did not quit: $process_path. No new build was opened"
    }
done

open -na "$app_path"

for _ in {1..20}; do
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] || continue
        if [[ "$(process_command "$process_id")" == "$expected_command" ]]; then
            echo "Opened $app_path"
            echo "Bundle identifier: $bundle_identifier"
            exit 0
        fi
    done < <(pgrep -u "$UID" -x Nativ || true)
    sleep 0.25
done

fail "Nativ did not remain running after launch"
