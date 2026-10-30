import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[2] / "PythonDistribution" / "Scripts"
sys.path.insert(0, str(SCRIPTS))
builder = importlib.import_module("build_mlx_vlm_server")
resource = importlib.import_module("build_xcode_framework_resource")
sys.path.pop(0)


class PythonResourceReuseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name).resolve() / "runtime"
        self.output.mkdir()
        self.sentinel = self.output / "installed-runtime"
        self.sentinel.write_text("preserve until rebuilt")
        self.signature = {"builder_sha256": "current", "requirements_sha256": "current"}
        self.patch(builder, "build_signature", return_value=self.signature)
        self.verify = self.patch(builder, "verify_distribution")
        self.install = self.patch(
            builder, "install_python", return_value=self.output / "python"
        )

    def patch(self, target, attribute, **kwargs):
        patcher = patch.object(target, attribute, **kwargs)
        value = patcher.start()
        self.addCleanup(patcher.stop)
        return value

    def run_builder(self, *options):
        with patch.object(
            sys, "argv", ["builder", "--output", str(self.output), *options]
        ):
            builder.main()

    def test_matching_signature_verifies_without_reinstalling(self):
        builder.write_stamp(self.output, self.signature)
        self.run_builder("--reuse-only")
        self.verify.assert_called_once_with(self.output, expect_mlx_vlm=True)
        self.install.assert_not_called()
        self.assertTrue(self.sentinel.exists())

    def test_stale_missing_and_corrupt_stamps_fail_without_mutating_runtime(self):
        for stamp in (None, "not json", json.dumps({"builder_sha256": "old"})):
            with self.subTest(stamp=stamp):
                path = self.output / builder.BUILD_STAMP
                if stamp is not None:
                    path.write_text(stamp)
                with self.assertRaisesRegex(
                    SystemExit, "Rebuild without NATIV_SKIP_PYTHON_RESOURCE_BUILD"
                ):
                    self.run_builder("--reuse-only")
                self.assertEqual(self.sentinel.read_text(), "preserve until rebuilt")
        self.install.assert_not_called()
        self.verify.assert_not_called()

    def test_missing_output_is_not_created_in_reuse_mode(self):
        self.output = self.output / "missing"
        with self.assertRaisesRegex(SystemExit, "missing or stale"):
            self.run_builder("--reuse-only")
        self.assertFalse(self.output.exists())
        self.install.assert_not_called()

    def test_matching_stamp_does_not_hide_invalid_distribution(self):
        builder.write_stamp(self.output, self.signature)
        self.verify.side_effect = RuntimeError("missing capability group")
        with self.assertRaisesRegex(RuntimeError, "missing capability group"):
            self.run_builder("--reuse-only")
        self.install.assert_not_called()

    def test_normal_build_replaces_stale_runtime_then_stamps_verified_result(self):
        builder.write_stamp(self.output, {"requirements_sha256": "old"})
        stages = Mock()
        for name in (
            "install_requirements",
            "install_overlay",
            "install_model_capabilities_manifest",
            "write_or_build_launcher",
            "verify_distribution",
        ):
            stages.attach_mock(self.patch(builder, name), name)
        stages.write_or_build_launcher.return_value = self.output / "bin/launcher"
        self.run_builder()
        self.assertFalse(self.sentinel.exists())
        self.install.assert_called_once()
        self.assertEqual(
            [call[0] for call in stages.mock_calls],
            [
                "install_requirements",
                "install_overlay",
                "install_model_capabilities_manifest",
                "write_or_build_launcher",
                "verify_distribution",
            ],
        )
        self.assertEqual(builder.read_stamp(self.output), self.signature)

    def test_xcode_skip_still_invokes_builder_and_propagates_stale_failure(self):
        self.patch(
            resource, "default_mlx_vlm_source", return_value=Path("/local/mlx-vlm")
        )
        self.patch(resource, "default_mlx_audio_source", return_value=None)
        run = self.patch(
            resource.subprocess, "run", side_effect=RuntimeError("stale runtime")
        )
        sign = self.patch(resource, "sign_embedded_code")
        with patch.dict(
            resource.os.environ, {"NATIV_SKIP_PYTHON_RESOURCE_BUILD": "YES"}
        ), patch.object(sys, "argv", ["resource", str(self.output)]):
            with self.assertRaisesRegex(RuntimeError, "stale runtime"):
                resource.main()
        command = run.call_args.args[0]
        self.assertIn("--reuse-only", command)
        self.assertEqual(command[-2:], ["--mlx-vlm-source", "/local/mlx-vlm"])
        sign.assert_not_called()


if __name__ == "__main__":
    unittest.main()
