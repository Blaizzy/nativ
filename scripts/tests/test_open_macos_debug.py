"""Exercise launch arbitration without opening or terminating real applications."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(os.environ.get("NATIV_LAUNCH_SCRIPT", Path(__file__).parents[1] / "open_macos_debug.sh"))


@unittest.skipUnless(sys.platform == "darwin", "Uses macOS PlistBuddy and shlock")
class DebugLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nativ-launch-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "this worktree" / "Nativ.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.local.Nativ"}))
        self.executable = str(self.app / "Contents/MacOS/Nativ")
        self.foreign = str(self.root / "other worktree/Nativ.app/Contents/MacOS/Nativ")
        self.processes = self.root / "processes"
        self.processes.write_text("")
        self.events = self.root / "events"
        self.events.write_text("")
        self.lock = self.root / "nativ-debug-launch.lock"
        self.hooks = self.root / "hooks.sh"
        self.hooks.write_text(r'''
getconf() { printf '%s\n' "$FIXTURE"; }
codesign() {
    [[ "${INVALID_SIGNATURE:-0}" == 0 ]] || return 1
    printf 'Authority=Apple Development: Fixture\nTeamIdentifier=FIXTURE\nanchor apple generic\n'
}
pgrep() { awk -F '\t' '{print $1}' "$FIXTURE/processes"; }
ps() { awk -F '\t' -v pid="$2" '$1 == pid {print "    " $2}' "$FIXTURE/processes"; }
kill() {
    printf 'kill %s\n' "$1" >> "$FIXTURE/events"
    [[ "${STALL_SHUTDOWN:-0}" == 0 ]] || return 0
    awk -F '\t' -v pid="$1" '$1 != pid' "$FIXTURE/processes" > "$FIXTURE/next"
    mv "$FIXTURE/next" "$FIXTURE/processes"
}
open() {
    printf 'open %s\n' "$2" >> "$FIXTURE/events"
    [[ "${WRONG_LAUNCH:-0}" == 0 ]] || return 0
    printf '99999\t%s/Contents/MacOS/Nativ\n' "$2" >> "$FIXTURE/processes"
}
sleep() { :; }
''')
        self.environment = dict(os.environ, BASH_ENV=str(self.hooks), FIXTURE=str(self.root))

    def running(self, *paths):
        self.processes.write_text("".join(f"{100 + i}\t{path}\n" for i, path in enumerate(paths)))

    def launch(self, *arguments, **environment):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *arguments, str(self.app)],
                                env=dict(self.environment, **environment), capture_output=True, text=True, timeout=10)
        self.assertFalse(self.lock.exists(), result.stderr)
        return result

    def test_fresh_launch_verifies_exact_bundle(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Opened {self.app}", result.stdout)
        self.assertEqual(self.events.read_text(), f"open {self.app}\n")

    def test_restart_stops_only_requested_bundle(self):
        self.running(self.executable)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events.read_text(), f"kill 100\nopen {self.app}\n")

    def test_other_worktree_is_left_running(self):
        self.running(self.foreign)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.foreign, result.stderr)
        self.assertIn("--replace-existing", result.stderr)
        self.assertEqual(self.events.read_text(), "")
        self.assertIn(self.foreign, self.processes.read_text())

    def test_foreign_preflight_does_not_stop_own_build_either(self):
        self.running(self.executable, self.foreign)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events.read_text(), "")
        self.assertIn(self.executable, self.processes.read_text())

    def test_explicit_switch_waits_for_other_build_to_exit(self):
        self.running(self.foreign)
        result = self.launch("--replace-existing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events.read_text(), f"kill 100\nopen {self.app}\n")
        self.assertNotIn(self.foreign, self.processes.read_text())

    def test_failed_shutdown_does_not_open_second_app(self):
        self.running(self.executable)
        result = self.launch(STALL_SHUTDOWN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not quit", result.stderr)
        self.assertEqual(self.events.read_text(), "kill 100\n")

    def test_invalid_signature_does_not_stop_any_app(self):
        self.running(self.executable)
        result = self.launch(INVALID_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events.read_text(), "")

    def test_failed_exact_path_verification_is_reported(self):
        result = self.launch(WRONG_LAUNCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not remain running", result.stderr)

    def test_another_launch_cannot_steal_active_lock(self):
        self.lock.write_text(f"{os.getpid()}\n")
        result = subprocess.run(["/bin/bash", str(SCRIPT), str(self.app)], env=self.environment,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another Nativ launch is in progress", result.stderr)
        self.assertEqual(self.events.read_text(), "")
        self.assertEqual(self.lock.read_text(), f"{os.getpid()}\n")


if __name__ == "__main__":
    unittest.main()
