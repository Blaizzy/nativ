import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "PythonDistribution/Scripts"))
import build_mlx_vlm_server as builder


class BundledServerRequirementsTests(unittest.TestCase):
    def test_local_source_overrides_vcs_pin_without_dropping_other_requirements(self):
        requirements_text = "mlx-vlm @ git+https://github.com/Blaizzy/mlx-vlm@revision\nmlx>=0.32.0\n"
        with tempfile.TemporaryDirectory() as directory:
            requirements = Path(directory) / "requirements.txt"
            requirements.write_text(requirements_text)
            for source in (None, Path(directory) / "mlx-vlm"):
                with self.subTest(local_source=source is not None):
                    captured = []

                    def capture(command, **kwargs):
                        resolved = Path(command[command.index("-r") + 1])
                        captured.append((command, resolved.read_text()))

                    with patch.object(builder, "run", side_effect=capture):
                        builder.install_requirements(
                            Path("python"), requirements=requirements,
                            mlx_vlm_source=source, mlx_audio_source=None, extra_pip_args=[]
                        )
                    command, text = captured[0]
                    self.assertIn("mlx>=0.32.0", text)
                    if source:
                        self.assertNotIn("mlx-vlm @", text)
                        self.assertIn(str(source), command)
                    else:
                        self.assertEqual(text, requirements_text)
                    self.assertEqual(requirements.read_text(), requirements_text)
