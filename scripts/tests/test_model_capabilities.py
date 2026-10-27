import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "model_capabilities",
    Path(__file__).parents[2] / "PythonDistribution/Scripts/generate_model_capabilities_manifest.py",
)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class EmbeddingOutput:
    pass


class RuntimeModelCapabilityTests(unittest.TestCase):
    def test_generation_contract_without_model_name_allowlist(self):
        class Autoregressive:
            def __call__(self, input_ids, cache=None):
                pass

        class Diffusion:
            def __call__(self, input_ids):
                pass

            def generate(self, input_ids):
                pass

        for model in [Autoregressive, Diffusion]:
            with self.subTest(model=model):
                self.assertEqual(manifest._runtime_model_capabilities(model), (True, False))

    def test_encoder_output_is_not_chat_generation(self):
        class AnnotatedEncoder:
            def __call__(self, input_ids, **kwargs) -> EmbeddingOutput:
                pass

        class UnannotatedEncoder:
            def __call__(self, input_ids, **kwargs):
                return EmbeddingOutput()

        class EncoderWithCache:
            def __call__(self, input_ids, cache=None):
                return EmbeddingOutput()

        for model in [AnnotatedEncoder, UnannotatedEncoder, EncoderWithCache]:
            with self.subTest(model=model):
                self.assertEqual(manifest._runtime_model_capabilities(model), (False, True))

    def test_vision_and_classification_loaders_are_not_chat_models(self):
        class Vision:
            def __call__(self, pixel_values):
                return {}

        self.assertEqual(manifest._runtime_model_capabilities(Vision), (False, False))




class DistributionRequirementTests(unittest.TestCase):
    def test_local_source_overrides_only_its_own_pin(self):
        import sys
        import tempfile
        from unittest.mock import patch

        scripts = Path(__file__).parents[2] / "PythonDistribution/Scripts"
        sys.path.insert(0, str(scripts))
        try:
            import build_mlx_vlm_server as builder
        finally:
            sys.path.pop(0)
        with tempfile.TemporaryDirectory() as folder:
            requirements = Path(folder) / "requirements.txt"
            original = "mlx-vlm @ git+https://example.com/runtime.git@abc\nmlx-audio>=0.6.2\n-r extra.txt\n"
            requirements.write_text(original)
            for override in (None, Path("/local/mlx-vlm")):
                observed = []
                def capture(command, **kwargs):
                    source = Path(command[command.index("-r") + 1])
                    observed.append((source, source.read_text()))
                    if override:
                        self.assertIn(str(override), command)
                with patch.object(builder, "run", side_effect=capture):
                    builder.install_requirements(Path("python"), requirements=requirements,
                        mlx_vlm_source=override, mlx_audio_source=None, extra_pip_args=[])
                source, text = observed[0]
                self.assertEqual(source.parent, requirements.parent)
                self.assertEqual(text, original if override is None else "mlx-audio>=0.6.2\n-r extra.txt\n")
                self.assertEqual(requirements.read_text(), original)
                if override:
                    self.assertFalse(source.exists())


if __name__ == "__main__":
    unittest.main()
