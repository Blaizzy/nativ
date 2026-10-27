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


if __name__ == "__main__":
    unittest.main()
