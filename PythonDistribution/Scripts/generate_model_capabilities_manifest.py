#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import importlib.metadata
import json
import subprocess
from pathlib import Path
from typing import Any


MANIFEST_FILENAME = "model-capabilities.json"
SCHEMA_VERSION = 1
CAPABILITY_NAMES = (
    "language",
    "speculative_drafters",
    "image_generation",
    "image_editing",
    "speech_to_text",
    "text_to_speech",
    "embeddings",
    "reranking",
    "decision",
)
PACKAGE_NAMES = ("mlx-vlm", "mlx-audio")


def _parse_module(path: Path) -> ast.Module:
    if not path.is_file():
        raise FileNotFoundError(f"Missing bundled loader source: {path}")
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _assignment_expression(
    scope: ast.Module | ast.ClassDef, name: str
) -> ast.expr | None:
    for statement in scope.body:
        if isinstance(statement, ast.Assign):
            if any(
                isinstance(target, ast.Name) and target.id == name
                for target in statement.targets
            ):
                return statement.value
        elif (
            isinstance(statement, ast.AnnAssign)
            and isinstance(statement.target, ast.Name)
            and statement.target.id == name
        ):
            return statement.value
    return None


def _literal_assignment(scope: ast.Module | ast.ClassDef, name: str) -> Any | None:
    value = _assignment_expression(scope, name)
    if value is None:
        return None
    try:
        return ast.literal_eval(value)
    except (ValueError, TypeError):
        return None


def _string_mapping(path: Path, name: str) -> dict[str, str]:
    value = _literal_assignment(_parse_module(path), name)
    if not isinstance(value, dict) or not all(
        isinstance(key, str) and isinstance(target, str)
        for key, target in value.items()
    ):
        raise RuntimeError(f"{path} does not define a literal {name} string mapping")
    return {
        key.strip().lower(): target.strip().lower()
        for key, target in value.items()
        if key.strip() and target.strip()
    }


def _literal_mapping_keys(path: Path, name: str) -> set[str]:
    value = _assignment_expression(_parse_module(path), name)
    if isinstance(value, ast.Dict):
        keys = {
            key.value.strip().lower()
            for key in value.keys
            if isinstance(key, ast.Constant)
            and isinstance(key.value, str)
            and key.value.strip()
        }
        if keys:
            return keys
    raise RuntimeError(f"{path} does not define a non-empty literal {name} mapping")


def _bound_names(path: Path) -> set[str]:
    names: set[str] = set()
    for statement in _parse_module(path).body:
        if isinstance(statement, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(statement.name)
        elif isinstance(statement, (ast.Import, ast.ImportFrom)):
            for alias in statement.names:
                names.add(alias.asname or alias.name.split(".")[-1])
        elif isinstance(statement, (ast.Assign, ast.AnnAssign)):
            targets = statement.targets if isinstance(statement, ast.Assign) else [
                statement.target
            ]
            names.update(target.id for target in targets if isinstance(target, ast.Name))
    return names


def _loader_packages(root: Path, *, requires_config_type: bool = True) -> set[str]:
    if not root.is_dir():
        raise FileNotFoundError(f"Missing bundled models directory: {root}")
    loaders: set[str] = set()
    for package in sorted(root.iterdir()):
        if not package.is_dir() or package.name.startswith("_"):
            continue
        initializer = package / "__init__.py"
        if not initializer.is_file():
            continue
        names = _bound_names(initializer)
        has_config_type = bool({"ModelConfig", "ModelArgs"} & names)
        if "Model" in names and (has_config_type or not requires_config_type):
            loaders.add(package.name.lower())
    if not loaders:
        raise RuntimeError(f"No model loaders found under {root}")
    return loaders


def _runtime_loader_mapping(
    site_packages: Path, candidate_model_types: set[str]
) -> tuple[dict[str, str], set[str]]:
    python = site_packages.parents[2] / "bin" / "python3"
    if not python.exists():
        raise FileNotFoundError(f"Missing bundled Python interpreter: {python}")

    resolver = """
import json
import sys

from mlx_vlm.utils import get_model_and_args

candidates = json.load(sys.stdin)
resolved = {}
decisions = set()
for candidate in candidates:
    module, loader = get_model_and_args({"model_type": candidate})
    if not hasattr(module, "Model") or not hasattr(module, "ModelConfig"):
        raise RuntimeError(
            f"Resolved loader {loader!r} for {candidate!r} does not expose "
            "Model and ModelConfig"
        )
    resolved[candidate] = loader
    if getattr(module.Model, "decision_types", ()):
        decisions.add(loader)
json.dump({"loaders": resolved, "decisions": sorted(decisions)}, sys.stdout, sort_keys=True)
"""
    result = subprocess.run(
        [str(python), "-c", resolver],
        input=json.dumps(sorted(candidate_model_types)),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(
            "Could not resolve model types with the bundled MLX runtime"
            + (f": {details}" if details else "")
        )

    try:
        payload = json.loads(result.stdout)
        mapping = payload["loaders"]
    except json.JSONDecodeError as error:
        raise RuntimeError("Bundled MLX resolver returned invalid JSON") from error
    if (
        not isinstance(mapping, dict)
        or set(mapping) != candidate_model_types
        or not all(
            isinstance(candidate, str)
            and isinstance(loader, str)
            and candidate.strip().lower() == candidate
            and loader.strip().lower() == loader
            for candidate, loader in mapping.items()
        )
    ):
        raise RuntimeError("Bundled MLX resolver returned an invalid loader mapping")
    decisions = set(payload["decisions"])
    if not decisions or not decisions.issubset(set(mapping.values())):
        raise RuntimeError("Bundled MLX runtime has no valid decision loaders")
    return mapping, decisions


def _configuration_aliases(utils_path: Path, resolved: dict[str, str]) -> list[dict[str, str]]:
    tree = _parse_module(utils_path)
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "get_model_type")
    aliases = []
    for node in ast.walk(function):
        if not isinstance(node, ast.If) or not isinstance(node.test, ast.BoolOp) or not isinstance(node.test.op, ast.And):
            continue
        conditions = node.test.values
        if len(conditions) != 2:
            continue
        match, suffix = conditions
        if not (isinstance(match, ast.Compare) and isinstance(match.left, ast.Name)
                and match.left.id == "model_type" and len(match.ops) == 1 and isinstance(match.ops[0], ast.Eq)
                and isinstance(match.comparators[0], ast.Constant) and isinstance(match.comparators[0].value, str)):
            continue
        if not (isinstance(suffix, ast.Call) and isinstance(suffix.func, ast.Attribute)
                and suffix.func.attr == "endswith" and len(suffix.args) == 1
                and isinstance(suffix.args[0], ast.Constant) and isinstance(suffix.args[0].value, str)):
            continue
        expression = ast.unparse(suffix.func.value)
        if expression != "str((config.get('auto_map') or {}).get('AutoModel', ''))":
            continue
        if len(node.body) != 1 or not isinstance(node.body[0], ast.Assign):
            raise RuntimeError("Unsupported runtime configuration alias assignment")
        assignment = node.body[0]
        if not (len(assignment.targets) == 1 and isinstance(assignment.targets[0], ast.Name)
                and assignment.targets[0].id == "model_type" and isinstance(assignment.value, ast.Constant)
                and assignment.value.value in resolved.values()):
            raise RuntimeError("Invalid runtime configuration alias target")
        aliases.append({"model_type": match.comparators[0].value,
                        "auto_model_suffix": suffix.args[0].value, "loader": assignment.value.value})
    return aliases


def _image_model_types(models_root: Path) -> tuple[set[str], set[str]]:
    if not models_root.is_dir():
        raise FileNotFoundError(f"Missing mlx-vlm models directory: {models_root}")
    generation_types: set[str] = set()
    editing_types: set[str] = set()
    for model_path in sorted(models_root.glob("*/model.py")):
        module = _parse_module(model_path)
        classes = {
            statement.name: statement
            for statement in module.body
            if isinstance(statement, ast.ClassDef)
        }

        def inherited_literal(
            class_name: str,
            name: str,
            visited: set[str] | None = None,
        ) -> Any | None:
            visited = set() if visited is None else visited
            if class_name in visited:
                return None
            visited.add(class_name)
            statement = classes.get(class_name)
            if statement is None:
                return None
            value = _literal_assignment(statement, name)
            if value is not None:
                return value
            for base in statement.bases:
                if isinstance(base, ast.Name):
                    value = inherited_literal(base.id, name, visited)
                    if value is not None:
                        return value
            return None

        for class_name in classes:
            model_type = inherited_literal(class_name, "model_type")
            if not isinstance(model_type, str) or not model_type.strip():
                continue
            model_type = model_type.strip().lower()
            if inherited_literal(class_name, "is_image_generation_model") is True:
                generation_types.add(model_type)
            if inherited_literal(class_name, "is_image_edit_model") is True:
                editing_types.add(model_type)
    if not generation_types or not editing_types:
        raise RuntimeError(f"Missing image model capabilities under {models_root}")
    return generation_types, editing_types


def _package_versions(site_packages: Path) -> dict[str, str]:
    installed = {
        distribution.metadata["Name"].lower(): distribution.version
        for distribution in importlib.metadata.distributions(path=[str(site_packages)])
        if distribution.metadata.get("Name")
    }
    missing = [name for name in PACKAGE_NAMES if name not in installed]
    if missing:
        raise RuntimeError(
            "Missing bundled package metadata for: " + ", ".join(sorted(missing))
        )
    return {name: installed[name] for name in PACKAGE_NAMES}


def _aliases_for(
    mapping: dict[str, str], canonical_model_types: set[str]
) -> dict[str, str]:
    return dict(
        sorted(
            (alias, target)
            for alias, target in mapping.items()
            if alias != target and target in canonical_model_types
        )
    )


def _apply_alias_precedence(
    model_types: set[str], mapping: dict[str, str]
) -> set[str]:
    aliases = {alias for alias, target in mapping.items() if alias != target}
    return model_types - aliases


def _validate_mapping_targets(
    mapping: dict[str, str], canonical_model_types: set[str]
) -> None:
    unresolved = {
        alias: target
        for alias, target in mapping.items()
        if target not in canonical_model_types
    }
    if unresolved:
        details = ", ".join(
            f"{alias}->{target}" for alias, target in sorted(unresolved.items())
        )
        raise RuntimeError(f"Aliases do not resolve to bundled loaders: {details}")


def _entry(
    model_types: set[str],
    aliases: dict[str, str] | None = None,
    kinds: dict[str, str] | None = None,
) -> dict[str, object]:
    entry: dict[str, object] = {
        "model_types": sorted(model_types),
        "aliases": dict(sorted((aliases or {}).items())),
    }
    if kinds is not None:
        entry["kinds"] = dict(sorted(kinds.items()))
    return entry


def model_capabilities(site_packages: Path) -> dict[str, object]:
    mlx_vlm_root = site_packages / "mlx_vlm"
    mlx_audio_root = site_packages / "mlx_audio"
    vlm_models_root = mlx_vlm_root / "models"

    language_loaders = _loader_packages(vlm_models_root)
    drafters_root = mlx_vlm_root / "speculative" / "drafters"
    drafter_loaders = _loader_packages(drafters_root)
    drafter_initializer = drafters_root / "__init__.py"
    explicit_drafter_kinds = _string_mapping(
        drafter_initializer, "DRAFTER_KIND_BY_MODEL_TYPE"
    )
    default_drafter_kind = _literal_assignment(
        _parse_module(drafter_initializer), "DEFAULT_DRAFTER_KIND"
    )
    known_drafter_kinds = _literal_assignment(
        _parse_module(drafter_initializer), "KNOWN_DRAFTER_KINDS"
    )
    if (
        not isinstance(default_drafter_kind, str)
        or not isinstance(known_drafter_kinds, set)
        or default_drafter_kind not in known_drafter_kinds
        or any(not isinstance(kind, str) for kind in known_drafter_kinds)
    ):
        raise RuntimeError(f"{drafter_initializer} has invalid drafter kind metadata")
    vlm_alias_mapping = _string_mapping(mlx_vlm_root / "utils.py", "MODEL_REMAPPING")
    all_loaders = language_loaders | drafter_loaders
    _validate_mapping_targets(vlm_alias_mapping, all_loaders)
    resolved_model_types, decision_types = _runtime_loader_mapping(
        site_packages,
        all_loaders | set(vlm_alias_mapping),
    )
    if set(resolved_model_types.values()) != all_loaders:
        missing = all_loaders - set(resolved_model_types.values())
        unexpected = set(resolved_model_types.values()) - all_loaders
        details = []
        if missing:
            details.append("unresolved loaders: " + ", ".join(sorted(missing)))
        if unexpected:
            details.append("unexpected loaders: " + ", ".join(sorted(unexpected)))
        raise RuntimeError("Bundled MLX loader mapping is incomplete: " + "; ".join(details))

    language_types = _apply_alias_precedence(language_loaders, resolved_model_types) - decision_types
    drafter_types = _apply_alias_precedence(drafter_loaders, resolved_model_types)
    language_aliases = _aliases_for(resolved_model_types, language_types)
    drafter_aliases = _aliases_for(resolved_model_types, drafter_types)
    resolved_drafter_kinds: dict[str, str] = {}
    for model_type, kind in explicit_drafter_kinds.items():
        loader = resolved_model_types.get(
            model_type,
            vlm_alias_mapping.get(model_type, model_type),
        )
        existing_kind = resolved_drafter_kinds.get(loader)
        if existing_kind is not None and existing_kind != kind:
            raise RuntimeError(f"Conflicting drafter kinds for loader {loader}")
        resolved_drafter_kinds[loader] = kind
    drafter_kinds = {
        model_type: resolved_drafter_kinds.get(model_type, default_drafter_kind)
        for model_type in drafter_types
    }

    image_generation_types, image_editing_types = _image_model_types(vlm_models_root)

    stt_types = _loader_packages(
        mlx_audio_root / "stt" / "models", requires_config_type=False
    )
    tts_types = _loader_packages(
        mlx_audio_root / "tts" / "models", requires_config_type=False
    )
    stt_alias_mapping = _string_mapping(
        mlx_audio_root / "stt" / "utils.py", "MODEL_REMAPPING"
    )
    tts_alias_mapping = _string_mapping(
        mlx_audio_root / "tts" / "utils.py", "MODEL_REMAPPING"
    )
    _validate_mapping_targets(stt_alias_mapping, stt_types)
    _validate_mapping_targets(tts_alias_mapping, tts_types)
    stt_types = _apply_alias_precedence(stt_types, stt_alias_mapping)
    tts_types = _apply_alias_precedence(tts_types, tts_alias_mapping)

    embedding_alias_mapping = _string_mapping(
        mlx_vlm_root / "embedding_loader.py", "EMBEDDING_MODEL_REMAPPING"
    )
    embedding_types = set(embedding_alias_mapping.values())
    _validate_mapping_targets(embedding_alias_mapping, language_types)

    reranking_types = _literal_mapping_keys(
        mlx_vlm_root / "reranker.py", "_RERANKER_KINDS"
    )
    reranking_alias_mapping = _string_mapping(
        mlx_vlm_root / "reranker_loader.py",
        "SEQUENCE_CLASSIFIER_MODEL_REMAPPING",
    )
    _validate_mapping_targets(reranking_alias_mapping, reranking_types)

    capabilities = {
        "decision": _entry(decision_types, _aliases_for(resolved_model_types, decision_types)),
        "language": _entry(
            language_types,
            language_aliases,
        ),
        "speculative_drafters": _entry(
            drafter_types,
            drafter_aliases,
            drafter_kinds,
        ),
        "image_generation": _entry(
            image_generation_types,
        ),
        "image_editing": _entry(
            image_editing_types,
        ),
        "speech_to_text": _entry(
            stt_types,
            _aliases_for(stt_alias_mapping, stt_types),
        ),
        "text_to_speech": _entry(
            tts_types,
            _aliases_for(tts_alias_mapping, tts_types),
        ),
        "embeddings": _entry(
            embedding_types,
            _aliases_for(embedding_alias_mapping, embedding_types),
        ),
        "reranking": _entry(
            reranking_types,
            _aliases_for(reranking_alias_mapping, reranking_types),
        ),
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "package_versions": _package_versions(site_packages),
        "capabilities": capabilities,
        "configuration_aliases": _configuration_aliases(mlx_vlm_root / "utils.py", resolved_model_types),
    }


def validate_manifest(manifest: object) -> None:
    if not isinstance(manifest, dict) or manifest.get("schema_version") != SCHEMA_VERSION:
        raise RuntimeError("Model capability manifest has an invalid schema version")
    package_versions = manifest.get("package_versions")
    if not isinstance(package_versions, dict) or any(
        not isinstance(package_versions.get(name), str)
        or not package_versions[name].strip()
        for name in PACKAGE_NAMES
    ):
        raise RuntimeError("Model capability manifest has incomplete package versions")
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, dict) or set(capabilities) != set(CAPABILITY_NAMES):
        raise RuntimeError("Model capability manifest has incomplete capabilities")
    for capability_name in CAPABILITY_NAMES:
        entry = capabilities[capability_name]
        if not isinstance(entry, dict):
            raise RuntimeError(f"Invalid {capability_name} capability entry")
        model_types = entry.get("model_types")
        aliases = entry.get("aliases")
        kinds = entry.get("kinds")
        if (
            not isinstance(model_types, list)
            or not model_types
            or any(
                not isinstance(value, str)
                or not value
                or value != value.strip().lower()
                for value in model_types
            )
            or len(set(model_types)) != len(model_types)
        ):
            raise RuntimeError(f"Invalid {capability_name} model types")
        if not isinstance(aliases, dict) or any(
            not isinstance(alias, str)
            or not alias
            or alias != alias.strip().lower()
            or not isinstance(target, str)
            or target != target.strip().lower()
            or alias == target
            or alias in model_types
            or target not in model_types
            for alias, target in aliases.items()
        ):
            raise RuntimeError(f"Invalid {capability_name} aliases")
        if capability_name == "speculative_drafters":
            if (
                not isinstance(kinds, dict)
                or set(kinds) != set(model_types)
                or any(
                    not isinstance(kind, str)
                    or kind not in {"dflash", "eagle3", "mtp"}
                    for kind in kinds.values()
                )
            ):
                raise RuntimeError("Invalid speculative drafter kinds")
        elif kinds is not None:
            raise RuntimeError(f"Unexpected {capability_name} model kinds")

    known_loaders = {model_type for entry in capabilities.values() for model_type in entry["model_types"]}
    configuration_aliases = manifest.get("configuration_aliases", [])
    if not isinstance(configuration_aliases, list) or any(
        not isinstance(alias, dict)
        or not isinstance(alias.get("model_type"), str)
        or not alias["model_type"]
        or alias["model_type"] != alias["model_type"].strip().lower()
        or not isinstance(alias.get("auto_model_suffix"), str)
        or not alias["auto_model_suffix"]
        or alias.get("loader") not in known_loaders
        for alias in configuration_aliases
    ):
        raise RuntimeError("Invalid runtime configuration aliases")


def generate_model_capabilities_manifest(site_packages: Path, output: Path) -> Path:
    manifest = model_capabilities(site_packages)
    validate_manifest(manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Describe every model loader bundled with Nativ's MLX runtime."
    )
    parser.add_argument("site_packages", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    generate_model_capabilities_manifest(
        args.site_packages.resolve(),
        args.output.resolve(),
    )


if __name__ == "__main__":
    main()
