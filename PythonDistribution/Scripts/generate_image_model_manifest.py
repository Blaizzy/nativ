#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path


MANIFEST_FILENAME = "image-model-capabilities.json"


def _literal_assignment(class_node: ast.ClassDef, name: str) -> object | None:
    for statement in class_node.body:
        value: ast.expr | None = None
        if isinstance(statement, ast.Assign):
            if any(
                isinstance(target, ast.Name) and target.id == name
                for target in statement.targets
            ):
                value = statement.value
        elif (
            isinstance(statement, ast.AnnAssign)
            and isinstance(statement.target, ast.Name)
            and statement.target.id == name
        ):
            value = statement.value

        if value is not None:
            try:
                return ast.literal_eval(value)
            except (ValueError, TypeError):
                return None
    return None


def image_generation_model_types(site_packages: Path) -> list[str]:
    models_root = site_packages / "mlx_vlm" / "models"
    if not models_root.is_dir():
        raise FileNotFoundError(f"Missing mlx-vlm models directory: {models_root}")

    model_types: set[str] = set()
    for model_path in sorted(models_root.glob("*/model.py")):
        module = ast.parse(
            model_path.read_text(encoding="utf-8"),
            filename=str(model_path),
        )
        for statement in module.body:
            if not isinstance(statement, ast.ClassDef):
                continue
            is_image_model = _literal_assignment(
                statement, "is_image_generation_model"
            )
            model_type = _literal_assignment(statement, "model_type")
            if (
                is_image_model is True
                and isinstance(model_type, str)
                and model_type
            ):
                model_types.add(model_type)

    if not model_types:
        raise RuntimeError(
            f"No image-generation model classes found under {models_root}"
        )
    return sorted(model_types)


def generate_image_model_manifest(site_packages: Path, output: Path) -> Path:
    manifest = {
        "schema_version": 1,
        "model_types": image_generation_model_types(site_packages),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Describe image-generation backends bundled with mlx-vlm."
    )
    parser.add_argument("site_packages", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    generate_image_model_manifest(
        args.site_packages.resolve(),
        args.output.resolve(),
    )


if __name__ == "__main__":
    main()
