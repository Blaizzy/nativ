import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "model_capabilities",
    Path(__file__).parents[2] / "PythonDistribution/Scripts/generate_model_capabilities_manifest.py",
)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class EmbeddingOutput:
    pass


class RuntimeModelCapabilityTests(unittest.TestCase):
    def test_manifest_includes_bundled_vad_and_diarization_loaders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def write(path, source):
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(source, encoding="utf-8")

            initializer = "class Model: pass\nclass ModelConfig: pass\n"
            write("mlx_vlm/models/chat/__init__.py", initializer)
            write("mlx_vlm/models/chat/model.py", "class Model:\n"
                  "    model_type = 'chat'\n    is_image_generation_model = True\n"
                  "    is_image_edit_model = True\n")
            write("mlx_vlm/speculative/drafters/draft/__init__.py", initializer)
            write("mlx_vlm/speculative/drafters/__init__.py",
                  "DRAFTER_KIND_BY_MODEL_TYPE = {}\nDEFAULT_DRAFTER_KIND = 'mtp'\n"
                  "KNOWN_DRAFTER_KINDS = {'mtp'}\n")
            write("mlx_vlm/utils.py", "MODEL_REMAPPING = {}\n")
            write("mlx_vlm/embedding_loader.py", "EMBEDDING_MODEL_REMAPPING = {'encoder': 'chat'}\n")
            write("mlx_vlm/reranker.py", "_RERANKER_KINDS = {'cross_encoder': None}\n")
            write("mlx_vlm/reranker_loader.py", "SEQUENCE_CLASSIFIER_MODEL_REMAPPING = {}\n")
            for category in ("stt", "tts"):
                write(f"mlx_audio/{category}/models/speech/__init__.py", initializer)
                write(f"mlx_audio/{category}/utils.py", "MODEL_REMAPPING = {}\n")
            # A newly bundled loader must be discovered without a name allowlist.
            vad_types = {"nemotron_diarization", "sortformer", "silero_vad", "future_vad"}
            for model_type in vad_types | {"silero"}:
                write(f"mlx_audio/vad/models/{model_type}/__init__.py", "class Model: pass\n")
            aliases = {"silero": "silero_vad", "silero-vad": "silero_vad"}
            write("mlx_audio/vad/utils.py", f"MODEL_REMAPPING = {aliases!r}\n")
            for package in ("mlx_vlm", "mlx_audio"):
                write(f"{package}-1.0.dist-info/METADATA",
                      f"Name: {package.replace('_', '-')}\nVersion: 1.0\n")

            runtime_metadata = ({"chat": "chat", "draft": "draft"}, {"chat"}, set())
            output = root / "model-capabilities.json"
            with patch.object(manifest, "_runtime_loader_metadata", return_value=runtime_metadata):
                manifest.generate_model_capabilities_manifest(root, output)
                data = json.loads(output.read_text())
                self.assertEqual(data["capabilities"]["voice_activity_detection"], {
                    "model_types": sorted(vad_types), "aliases": aliases,
                })

                # Invalid VAD aliases must fail the build just like other loaders.
                write("mlx_audio/vad/utils.py", "MODEL_REMAPPING = {'missing': 'not_bundled'}\n")
                with self.assertRaisesRegex(RuntimeError, "Aliases do not resolve to bundled loaders"):
                    manifest.model_capabilities(root)

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
