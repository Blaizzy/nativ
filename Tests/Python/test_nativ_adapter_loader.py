from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from PythonDistribution.Overlay.nativ_adapter_loader import (
    AdapterCompatibilityError,
    apply_validated_lora_adapter,
    convert_peft_adapter_weights,
    default_lora_layer_target,
    normalize_peft_lora_config,
    peft_weight_name_to_mlx,
    read_adapter_config,
    resolve_lora_config_for_model,
    resolve_lora_module_keys,
    resolve_adapter_weight_mapping,
    validate_adapter_config,
    validate_adapter_package,
)


class AdapterConfigTests(unittest.TestCase):
    def test_accepts_native_mlx_lora_config(self) -> None:
        validate_adapter_config(
            {
                "fine_tune_type": "lora",
                "lora_parameters": {"rank": 8, "scale": 2.0, "dropout": 0.0},
            }
        )

    def test_accepts_and_normalizes_standard_peft_lora_config(self) -> None:
        config = {
            "peft_type": "LORA",
            "r": 16,
            "lora_alpha": 32,
            "lora_dropout": 0.05,
            "bias": "none",
            "rank_pattern": {},
            "alpha_pattern": {},
        }
        validate_adapter_config(config)

        self.assertEqual(
            normalize_peft_lora_config(
                config,
                [
                    "model.layers.0.self_attn.q_proj.lora_a",
                    "model.layers.0.self_attn.q_proj.lora_b",
                ],
            ),
            {
                "fine_tune_type": "lora",
                "lora_parameters": {
                    "rank": 16,
                    "scale": 2.0,
                    "dropout": 0.05,
                    "keys": ["model.layers.0.self_attn.q_proj"],
                },
            },
        )

    def test_translates_peft_tensor_names_without_guessing_namespaces(self) -> None:
        self.assertEqual(
            peft_weight_name_to_mlx(
                "base_model.model.model.layers.0.self_attn.q_proj.lora_A.weight"
            ),
            "model.layers.0.self_attn.q_proj.lora_a",
        )
        with self.assertRaisesRegex(AdapterCompatibilityError, "namespace"):
            peft_weight_name_to_mlx("model.layers.0.q_proj.lora_A.weight")

    def test_converts_peft_tensor_names_and_orientation(self) -> None:
        class FakeTensor:
            def __init__(self, transposed: str) -> None:
                self.T = transposed

        converted = convert_peft_adapter_weights(
            {
                "base_model.model.model.layers.0.q_proj.lora_A.weight": FakeTensor(
                    "transposed-a"
                ),
                "base_model.model.model.layers.0.q_proj.lora_B.weight": FakeTensor(
                    "transposed-b"
                ),
            }
        )
        self.assertEqual(
            converted,
            {
                "model.layers.0.q_proj.lora_a": "transposed-a",
                "model.layers.0.q_proj.lora_b": "transposed-b",
            },
        )

    def test_rejects_peft_options_that_cannot_be_applied_losslessly(self) -> None:
        with self.assertRaisesRegex(AdapterCompatibilityError, "rank_pattern"):
            validate_adapter_config(
                {
                    "peft_type": "LORA",
                    "r": 8,
                    "rank_pattern": {"q_proj": 4},
                }
            )

    def test_peft_config_requires_its_canonical_r_field(self) -> None:
        with self.assertRaisesRegex(AdapterCompatibilityError, "positive integer"):
            validate_adapter_config({"peft_type": "LORA", "rank": 8})

    def test_rejects_non_lora_and_boolean_rank(self) -> None:
        with self.assertRaisesRegex(AdapterCompatibilityError, "supports LoRA only"):
            validate_adapter_config(
                {"fine_tune_type": "dora", "lora_parameters": {"rank": 8}}
            )
        with self.assertRaisesRegex(AdapterCompatibilityError, "positive integer"):
            validate_adapter_config({"lora_parameters": {"rank": True}})

    def test_reads_config_from_package_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory)
            expected = {"fine_tune_type": "lora", "lora_parameters": {"rank": 4}}
            (path / "adapter_config.json").write_text(json.dumps(expected))
            self.assertEqual(read_adapter_config(path), expected)

    def test_package_preflight_requires_both_native_mlx_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory)
            (path / "adapter_config.json").write_text(
                json.dumps({"lora_parameters": {"rank": 4}})
            )
            with self.assertRaisesRegex(AdapterCompatibilityError, "adapters.safetensors"):
                validate_adapter_package(str(path))

            (path / "adapters.safetensors").write_bytes(b"weights")
            self.assertEqual(validate_adapter_package(str(path)), str(path.resolve()))

    def test_package_preflight_selects_peft_weights_from_peft_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory)
            (path / "adapter_config.json").write_text(
                json.dumps({"peft_type": "LORA", "r": 16})
            )
            (path / "adapters.safetensors").write_bytes(b"stale native weights")
            with self.assertRaisesRegex(
                AdapterCompatibilityError,
                "adapter_model.safetensors",
            ):
                validate_adapter_package(str(path))

            (path / "adapter_model.safetensors").write_bytes(b"peft weights")
            self.assertEqual(validate_adapter_package(str(path)), str(path.resolve()))


class AdapterWeightMappingTests(unittest.TestCase):
    source = {
        "model.layers.0.self_attn.q_proj.lora_a": (4, 16),
        "model.layers.0.self_attn.q_proj.lora_b": (16, 4),
    }

    def test_prefers_exact_mapping(self) -> None:
        mapping, kind = resolve_adapter_weight_mapping(self.source, self.source)
        self.assertEqual(mapping, {key: key for key in self.source})
        self.assertEqual(kind, "identity")

    def test_resolves_unique_mlx_vlm_wrapper_prefix(self) -> None:
        target = {f"language_model.{key}": shape for key, shape in self.source.items()}
        mapping, kind = resolve_adapter_weight_mapping(self.source, target)
        self.assertEqual(
            mapping,
            {key: f"language_model.{key}" for key in self.source},
        )
        self.assertEqual(kind, "wrapper-prefix")

    def test_rejects_shape_mismatch(self) -> None:
        target = dict(self.source)
        target["model.layers.0.self_attn.q_proj.lora_a"] = (8, 16)
        with self.assertRaisesRegex(AdapterCompatibilityError, "Shape mismatch"):
            resolve_adapter_weight_mapping(self.source, target)

    def test_rejects_missing_source_or_target_pairs(self) -> None:
        incomplete_source = {
            "model.layers.0.self_attn.q_proj.lora_a": (4, 16),
        }
        with self.assertRaisesRegex(AdapterCompatibilityError, "incomplete LoRA A/B"):
            resolve_adapter_weight_mapping(incomplete_source, self.source)

        extra_target = dict(self.source)
        extra_target.update(
            {
                "model.layers.1.self_attn.q_proj.lora_a": (4, 16),
                "model.layers.1.self_attn.q_proj.lora_b": (16, 4),
            }
        )
        with self.assertRaisesRegex(AdapterCompatibilityError, "missing tensors"):
            resolve_adapter_weight_mapping(self.source, extra_target)

    def test_rejects_ambiguous_or_non_lora_tensors(self) -> None:
        source = {"q_proj.lora_a": (4, 16), "q_proj.lora_b": (16, 4)}
        target = {
            "model.layers.0.q_proj.lora_a": (4, 16),
            "model.layers.0.q_proj.lora_b": (16, 4),
            "model.layers.1.q_proj.lora_a": (4, 16),
            "model.layers.1.q_proj.lora_b": (16, 4),
        }
        with self.assertRaisesRegex(AdapterCompatibilityError, "ambiguous"):
            resolve_adapter_weight_mapping(source, target)

        with self.assertRaisesRegex(AdapterCompatibilityError, "non-LoRA"):
            resolve_adapter_weight_mapping({"model.weight": (16, 16)}, self.source)


class AdapterModelApplicationTests(unittest.TestCase):
    def test_resolves_wrapper_prefixed_module_keys_for_inner_model(self) -> None:
        class InnerModel:
            def named_modules(self):
                return [("layers.0.self_attn.q_proj", object())]

        config = {
            "lora_parameters": {
                "rank": 4,
                "scale": 1.0,
                "dropout": 0.0,
                "keys": ["model.layers.0.self_attn.q_proj"],
            }
        }
        resolved = resolve_lora_config_for_model(config, InnerModel())
        self.assertEqual(
            resolved["lora_parameters"]["keys"],
            ["layers.0.self_attn.q_proj"],
        )
        self.assertEqual(
            config["lora_parameters"]["keys"],
            ["model.layers.0.self_attn.q_proj"],
        )

    def test_module_resolution_rejects_missing_and_ambiguous_paths(self) -> None:
        with self.assertRaisesRegex(AdapterCompatibilityError, "does not exist"):
            resolve_lora_module_keys(["model.layers.0.q_proj"], ["layers.0.k_proj"])
        with self.assertRaisesRegex(AdapterCompatibilityError, "ambiguous"):
            resolve_lora_module_keys(
                ["q_proj"],
                ["layers.0.q_proj", "layers.1.q_proj"],
            )

    def test_keyless_config_uses_nested_transformer_layers(self) -> None:
        class Transformer:
            layers = [object()]

        class CausalModel:
            model = Transformer()

        self.assertIs(default_lora_layer_target(CausalModel()), CausalModel.model)

    def test_applies_peft_adapter_to_text_model_without_model_attribute(self) -> None:
        class Weight:
            def __init__(self, shape):
                self.shape = shape

        class PeftWeight:
            def __init__(self, transposed_shape):
                self.T = Weight(transposed_shape)

        class InnerModel:
            def __init__(self):
                self.applied_keys = None
                self.loaded_weights = None
                self._parameters = {}

            def named_modules(self):
                return [("layers.0.self_attn.q_proj", object())]

            def parameters(self):
                return self._parameters

            def load_weights(self, weights, strict):
                self.loaded_weights = (weights, strict)

        class LanguageModel:
            def __init__(self):
                self._model = InnerModel()

        class TextModel:
            _is_text_model = True

            def __init__(self):
                self.language_model = LanguageModel()

        class TrainerUtils:
            @staticmethod
            def _apply_lora_layers(target, config):
                target.applied_keys = config["lora_parameters"]["keys"]
                target._parameters = {
                    "layers.0.self_attn.q_proj.lora_a": Weight((16, 4)),
                    "layers.0.self_attn.q_proj.lora_b": Weight((4, 16)),
                }
                return target

        class MX:
            @staticmethod
            def load(_):
                prefix = "base_model.model.model.layers.0.self_attn.q_proj"
                return {
                    f"{prefix}.lora_A.weight": PeftWeight((16, 4)),
                    f"{prefix}.lora_B.weight": PeftWeight((4, 16)),
                }

        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory)
            (path / "adapter_config.json").write_text(
                json.dumps({"peft_type": "LORA", "r": 4, "lora_alpha": 8})
            )
            (path / "adapter_model.safetensors").write_bytes(b"weights")
            model = TextModel()
            loaded_model, report = apply_validated_lora_adapter(
                model,
                str(path),
                trainer_utils=TrainerUtils,
                mx=MX,
                tree_flatten=lambda values: list(values.items()),
            )

        self.assertIs(loaded_model, model)
        self.assertEqual(
            model.language_model._model.applied_keys,
            ["layers.0.self_attn.q_proj"],
        )
        self.assertEqual(report.matched_tensors, 2)
        self.assertEqual(report.expected_tensors, 2)
        self.assertEqual(report.namespace_mapping, "wrapper-prefix")
        self.assertFalse(model.language_model._model.loaded_weights[1])


if __name__ == "__main__":
    unittest.main()
