from __future__ import annotations

import argparse
import json
import math
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


LORA_SUFFIXES = (".lora_a", ".lora_b")
MAX_ADAPTER_CONFIG_BYTES = 1024 * 1024
UNSUPPORTED_PEFT_FIELDS = (
    "alora_invocation_tokens",
    "alpha_pattern",
    "arrow_config",
    "layer_replication",
    "modules_to_save",
    "rank_pattern",
    "target_parameters",
    "trainable_token_indices",
    "use_bdlora",
)


class AdapterCompatibilityError(ValueError):
    """Raised when an adapter cannot be applied without dropping weights."""


@dataclass(frozen=True)
class AdapterValidationReport:
    adapter_path: str
    matched_tensors: int
    expected_tensors: int
    namespace_mapping: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _is_lora_key(key: str) -> bool:
    return key.endswith(LORA_SUFFIXES)


def _paired_key(key: str) -> str:
    if key.endswith(".lora_a"):
        return key[: -len(".lora_a")] + ".lora_b"
    if key.endswith(".lora_b"):
        return key[: -len(".lora_b")] + ".lora_a"
    raise AdapterCompatibilityError(f"Unsupported adapter tensor: {key}")


def validate_adapter_config(config: Mapping[str, Any]) -> None:
    if is_peft_lora_config(config):
        peft_type = config.get("peft_type", "LORA")
        if not isinstance(peft_type, str) or peft_type.upper() != "LORA":
            raise AdapterCompatibilityError(
                f"Unsupported PEFT adapter type {peft_type!r}; Nativ currently supports LoRA only."
            )
        if config.get("use_dora") is True:
            raise AdapterCompatibilityError("PEFT DoRA adapters are not supported.")
    else:
        fine_tune_type = config.get("fine_tune_type", "lora")
        if fine_tune_type != "lora":
            raise AdapterCompatibilityError(
                f"Unsupported adapter fine_tune_type {fine_tune_type!r}; Nativ currently supports LoRA only."
            )

    lora_parameters = config.get("lora_parameters")
    if is_peft_lora_config(config):
        rank = config.get("r")
    else:
        rank = (
            lora_parameters.get("rank")
            if isinstance(lora_parameters, dict)
            else config.get("rank")
        )
    if not isinstance(rank, int) or isinstance(rank, bool) or rank <= 0:
        raise AdapterCompatibilityError(
            "adapter_config.json must contain a positive integer LoRA rank."
        )
    if is_peft_lora_config(config):
        validate_peft_lora_options(config)


def validate_peft_lora_options(config: Mapping[str, Any]) -> None:
    """Reject PEFT behavior that the MLX runtime cannot preserve exactly."""

    unsupported = [field for field in UNSUPPORTED_PEFT_FIELDS if config.get(field)]
    if unsupported:
        raise AdapterCompatibilityError(
            "Unsupported PEFT LoRA options: " + ", ".join(unsupported) + "."
        )
    if config.get("bias", "none") != "none" or config.get("lora_bias") is True:
        raise AdapterCompatibilityError("PEFT LoRA bias weights are not supported.")

    rank = int(config["r"])
    alpha = _finite_number(config.get("lora_alpha", rank), "lora_alpha")
    dropout = _finite_number(config.get("lora_dropout", 0.0), "lora_dropout")
    if alpha <= 0:
        raise AdapterCompatibilityError("PEFT lora_alpha must be positive.")
    if dropout < 0 or dropout >= 1:
        raise AdapterCompatibilityError(
            "PEFT lora_dropout must be greater than or equal to 0 and less than 1."
        )


def is_peft_lora_config(config: Mapping[str, Any]) -> bool:
    return "peft_type" in config or "r" in config


def normalize_peft_lora_config(
    config: Mapping[str, Any],
    native_weight_keys: Sequence[str],
) -> dict[str, Any]:
    """Translate standard PEFT LoRA settings to mlx-vlm's in-memory schema."""

    validate_adapter_config(config)
    if not is_peft_lora_config(config):
        return dict(config)

    rank = int(config["r"])
    alpha = _finite_number(config.get("lora_alpha", rank), "lora_alpha")
    dropout = _finite_number(config.get("lora_dropout", 0.0), "lora_dropout")
    if alpha <= 0:
        raise AdapterCompatibilityError("PEFT lora_alpha must be positive.")
    if dropout < 0 or dropout >= 1:
        raise AdapterCompatibilityError(
            "PEFT lora_dropout must be greater than or equal to 0 and less than 1."
        )
    denominator = math.sqrt(rank) if config.get("use_rslora") is True else rank
    module_keys = sorted({_native_lora_module_key(key) for key in native_weight_keys})
    return {
        "fine_tune_type": "lora",
        "lora_parameters": {
            "rank": rank,
            "scale": alpha / denominator,
            "dropout": dropout,
            "keys": module_keys,
        },
    }


def _finite_number(value: Any, name: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise AdapterCompatibilityError(f"PEFT {name} must be a finite number.")
    result = float(value)
    if not math.isfinite(result):
        raise AdapterCompatibilityError(f"PEFT {name} must be a finite number.")
    return result


def _native_lora_module_key(key: str) -> str:
    for suffix in LORA_SUFFIXES:
        if key.endswith(suffix):
            return key[: -len(suffix)]
    raise AdapterCompatibilityError(f"Unsupported adapter tensor: {key}")


def peft_weight_name_to_mlx(key: str) -> str:
    prefix = "base_model.model."
    if not key.startswith(prefix):
        raise AdapterCompatibilityError(
            f"Unsupported PEFT adapter tensor namespace: {key}"
        )
    key = key[len(prefix) :]
    suffixes = (
        (".lora_A.weight", ".lora_a"),
        (".lora_B.weight", ".lora_b"),
    )
    for source_suffix, destination_suffix in suffixes:
        if key.endswith(source_suffix):
            return key[: -len(source_suffix)] + destination_suffix
    raise AdapterCompatibilityError(f"Unsupported PEFT adapter tensor: {key}")


def convert_peft_adapter_weights(weights: Mapping[str, Any]) -> dict[str, Any]:
    converted: dict[str, Any] = {}
    for source_name, value in weights.items():
        destination_name = peft_weight_name_to_mlx(source_name)
        if destination_name in converted:
            raise AdapterCompatibilityError(
                f"Multiple PEFT tensors resolve to {destination_name!r}."
            )
        converted[destination_name] = value.T
    return converted


def resolve_lora_module_keys(
    source_keys: Sequence[str],
    target_keys: Sequence[str],
) -> list[str]:
    """Resolve adapter module paths against a concrete MLX model namespace."""

    available = set(target_keys)
    resolved: list[str] = []
    used_targets: set[str] = set()
    for source_key in source_keys:
        if not isinstance(source_key, str) or not source_key:
            raise AdapterCompatibilityError(
                "The adapter configuration contains an invalid LoRA module key."
            )
        if source_key in available:
            candidates = [source_key]
        else:
            candidates = sorted(
                target_key
                for target_key in available
                if target_key.endswith("." + source_key)
                or source_key.endswith("." + target_key)
            )
        if not candidates:
            raise AdapterCompatibilityError(
                f"LoRA module {source_key!r} does not exist in the selected base model."
            )
        if len(candidates) > 1:
            raise AdapterCompatibilityError(
                f"LoRA module {source_key!r} has an ambiguous model mapping."
            )
        target_key = candidates[0]
        if target_key in used_targets:
            raise AdapterCompatibilityError(
                f"Multiple LoRA module keys resolve to {target_key!r}."
            )
        resolved.append(target_key)
        used_targets.add(target_key)
    return resolved


def resolve_lora_config_for_model(
    config: Mapping[str, Any],
    model: Any,
) -> dict[str, Any]:
    """Return a copy whose explicit module keys match the runtime model."""

    result = dict(config)
    parameters = result.get("lora_parameters")
    if not isinstance(parameters, dict) or "keys" not in parameters:
        return result
    source_keys = parameters["keys"]
    if not isinstance(source_keys, list) or not source_keys:
        raise AdapterCompatibilityError(
            "The adapter configuration must contain non-empty LoRA module keys."
        )
    target_keys = [name for name, _ in model.named_modules() if name]
    resolved_parameters = dict(parameters)
    resolved_parameters["keys"] = resolve_lora_module_keys(source_keys, target_keys)
    result["lora_parameters"] = resolved_parameters
    return result


def default_lora_layer_target(model: Any) -> Any:
    """Find the transformer block owner used by mlx-vlm's keyless LoRA format."""

    if hasattr(model, "layers"):
        return model
    nested_model = getattr(model, "model", None)
    if nested_model is not None and hasattr(nested_model, "layers"):
        return nested_model
    raise AdapterCompatibilityError(
        "The selected base model does not expose transformer layers for this adapter."
    )


def read_adapter_config(adapter_path: Path) -> dict[str, Any]:
    config_path = adapter_path / "adapter_config.json"
    if not config_path.is_file():
        raise AdapterCompatibilityError(
            f"Missing adapter_config.json in {adapter_path}."
        )
    if config_path.stat().st_size > MAX_ADAPTER_CONFIG_BYTES:
        raise AdapterCompatibilityError("adapter_config.json is unexpectedly large.")

    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AdapterCompatibilityError(
            f"Invalid adapter_config.json: {error}"
        ) from error
    if not isinstance(config, dict):
        raise AdapterCompatibilityError("adapter_config.json must contain a JSON object.")
    validate_adapter_config(config)
    return config


def validate_adapter_package(adapter_path: str) -> str:
    """Validate package-level requirements without mutating a loaded model."""

    canonical_path = Path(os.path.realpath(os.path.expanduser(adapter_path)))
    if not canonical_path.is_dir():
        raise AdapterCompatibilityError(
            f"The adapter path is not a directory: {canonical_path}."
        )
    config = read_adapter_config(canonical_path)
    weights_name = (
        "adapter_model.safetensors"
        if is_peft_lora_config(config)
        else "adapters.safetensors"
    )
    if not (canonical_path / weights_name).is_file():
        raise AdapterCompatibilityError(
            f"Missing {weights_name} in {canonical_path}."
        )
    return str(canonical_path)


def resolve_adapter_weight_mapping(
    source_shapes: Mapping[str, Sequence[int]],
    target_shapes: Mapping[str, Sequence[int]],
) -> tuple[dict[str, str], str]:
    """Resolve adapter keys to model keys without silently dropping a tensor.

    MLX text models can be wrapped by MLX-VLM under ``language_model``. A LoRA
    trained by MLX-LM therefore has the same meaningful parameter path with a
    different wrapper prefix. Exact matching is preferred; a suffix mapping is
    accepted only when it is unique and shape-compatible.
    """

    if not source_shapes:
        raise AdapterCompatibilityError("The adapter contains no tensors.")

    unsupported = sorted(key for key in source_shapes if not _is_lora_key(key))
    if unsupported:
        preview = ", ".join(unsupported[:3])
        raise AdapterCompatibilityError(
            f"The adapter contains unsupported non-LoRA tensors: {preview}."
        )

    missing_pairs = sorted(
        key for key in source_shapes if _paired_key(key) not in source_shapes
    )
    if missing_pairs:
        preview = ", ".join(missing_pairs[:3])
        raise AdapterCompatibilityError(
            f"The adapter contains incomplete LoRA A/B pairs: {preview}."
        )

    lora_targets = {
        key: tuple(int(dimension) for dimension in shape)
        for key, shape in target_shapes.items()
        if _is_lora_key(key)
    }
    if not lora_targets:
        raise AdapterCompatibilityError(
            "The model did not expose any LoRA parameters after applying the adapter configuration."
        )

    mapping: dict[str, str] = {}
    used_targets: set[str] = set()
    used_suffix_mapping = False

    for source_key, source_shape_value in source_shapes.items():
        source_shape = tuple(int(dimension) for dimension in source_shape_value)
        if source_key in lora_targets:
            candidates = [source_key]
        else:
            candidates = [
                target_key
                for target_key in lora_targets
                if target_key.endswith("." + source_key)
                or source_key.endswith("." + target_key)
            ]

        if not candidates:
            raise AdapterCompatibilityError(
                f"Adapter tensor {source_key!r} does not exist in the selected base model."
            )
        if len(candidates) > 1:
            raise AdapterCompatibilityError(
                f"Adapter tensor {source_key!r} has an ambiguous model mapping."
            )

        target_key = candidates[0]
        if target_key in used_targets:
            raise AdapterCompatibilityError(
                f"Multiple adapter tensors resolve to model tensor {target_key!r}."
            )
        if source_shape != lora_targets[target_key]:
            raise AdapterCompatibilityError(
                f"Shape mismatch for {source_key!r}: adapter {source_shape}, "
                f"model {lora_targets[target_key]}."
            )

        mapping[source_key] = target_key
        used_targets.add(target_key)
        used_suffix_mapping = used_suffix_mapping or source_key != target_key

    missing_targets = sorted(set(lora_targets) - used_targets)
    if missing_targets:
        preview = ", ".join(missing_targets[:3])
        raise AdapterCompatibilityError(
            f"The adapter is incomplete for its configuration; missing tensors: {preview}."
        )

    return mapping, "wrapper-prefix" if used_suffix_mapping else "identity"


def apply_validated_lora_adapter(
    model: Any,
    adapter_path: str,
    *,
    trainer_utils: Any,
    mx: Any,
    tree_flatten: Any,
) -> tuple[Any, AdapterValidationReport]:
    """Apply a supported LoRA package and return a verifiable load report."""

    canonical_path = Path(validate_adapter_package(adapter_path))
    config = read_adapter_config(canonical_path)
    peft_format = is_peft_lora_config(config)
    weights_path = canonical_path / (
        "adapter_model.safetensors" if peft_format else "adapters.safetensors"
    )
    is_text_model = getattr(model, "_is_text_model", False)
    target = model.language_model._model if is_text_model else model

    weights = mx.load(str(weights_path))
    if not isinstance(weights, dict):
        raise AdapterCompatibilityError(
            f"{weights_path.name} did not decode to a tensor mapping."
        )
    if peft_format:
        weights = convert_peft_adapter_weights(weights)
        config = normalize_peft_lora_config(config, list(weights))

    if "lora_parameters" in config:
        if "keys" in config["lora_parameters"]:
            config = resolve_lora_config_for_model(config, target)
            target = trainer_utils._apply_lora_layers(target, config)
        else:
            layer_target = default_lora_layer_target(target)
            applied_target = trainer_utils._apply_lora_layers(layer_target, config)
            if layer_target is target:
                target = applied_target
            elif applied_target is not layer_target:
                target.model = applied_target
    else:
        if is_text_model:
            raise AdapterCompatibilityError(
                "Legacy rank-only LoRA configurations are not supported for text-only models."
            )
        target = trainer_utils._apply_legacy_lora_layers(target, config)

    target_parameters = dict(tree_flatten(target.parameters()))
    source_shapes = {key: tuple(value.shape) for key, value in weights.items()}
    target_shapes = {key: tuple(value.shape) for key, value in target_parameters.items()}
    mapping, mapping_kind = resolve_adapter_weight_mapping(
        source_shapes,
        target_shapes,
    )

    mapped_weights = [(mapping[key], value) for key, value in weights.items()]
    target.load_weights(mapped_weights, strict=False)

    if is_text_model:
        model.language_model._model = target
        result_model = model
    else:
        result_model = target

    report = AdapterValidationReport(
        adapter_path=str(canonical_path),
        matched_tensors=len(mapped_weights),
        expected_tensors=len(
            [key for key in target_parameters if _is_lora_key(key)]
        ),
        namespace_mapping=mapping_kind,
    )
    return result_model, report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate LoRA packages using Nativ's runtime rules."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate-package")
    validate_parser.add_argument("adapter_path")
    arguments = parser.parse_args(argv)

    try:
        canonical_path = validate_adapter_package(arguments.adapter_path)
    except AdapterCompatibilityError as error:
        parser.exit(2, f"{error}\n")

    print(json.dumps({"status": "valid", "adapter_path": canonical_path}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
