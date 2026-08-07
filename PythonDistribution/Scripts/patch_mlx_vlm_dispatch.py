#!/usr/bin/env python3
"""Patch mlx-vlm's image-generation model dispatch so Bonsai repos win.

Root cause (stock mlx-vlm 0.6.10): `_local_image_model_types` classifies a
Bonsai repo as "flux2" *before* the manifest check can report "bonsai",
because Bonsai ships FLUX.2 configs (Flux2KleinPipeline /
Flux2Transformer2DModel). The flux2 loader is then invoked on Bonsai
weights and fails variant inference ("Could not infer Flux2 variant from
local model path ... Use a recognized model id or a path containing
4B/9B in its name").

Fix (3 idempotent edits to mlx_vlm/generate/image.py):
  1. `_local_image_model_types` checks manifest.json first — the Bonsai
     layout (transformer-packed-mflux + text_encoder-mlx-4bit + tokenizer)
     is the authoritative discriminator.
  2. `load_image_generation_model` checks the explicit model-id type first.
  3. `_image_generation_model_class_from_path` same id-first ordering.

Run from the build pipeline after pip install; also usable directly against
a built server resource (e.g. for a stale bundle).
"""

from __future__ import annotations

import sys
from pathlib import Path

# (old, new) exact-string replacements. `new` wins if already present
# (idempotent). A missing `old` raises so version drift is loud, not silent.
REPLACEMENTS: list[tuple[str, str]] = [
    (
        """    candidates: list[str] = []
    for filename in ("model_index.json", "config.json"):
        metadata = _load_json_file(root / filename)
        if metadata is not None:
            for model_type in _image_model_types_from_metadata(metadata):
                _add_model_type(candidates, model_type)

    manifest = _load_json_file(root / "manifest.json")
    if manifest is not None:
        _add_model_type(candidates, _image_model_type_from_manifest(manifest))
    _add_model_type(candidates, _image_model_type_from_component_indexes(root))""",
        """    candidates: list[str] = []
    manifest = _load_json_file(root / "manifest.json")
    if manifest is not None:
        # Bonsai repos ship FLUX.2 configs (Flux2KleinPipeline /
        # Flux2Transformer2DModel), so class-name scanning below would
        # classify them as flux2 before the manifest check. The manifest
        # layout (transformer-packed-mflux + text_encoder-mlx-4bit +
        # tokenizer) is the authoritative Bonsai discriminator, so it must
        # be checked first.
        _add_model_type(candidates, _image_model_type_from_manifest(manifest))

    for filename in ("model_index.json", "config.json"):
        metadata = _load_json_file(root / filename)
        if metadata is not None:
            for model_type in _image_model_types_from_metadata(metadata):
                _add_model_type(candidates, model_type)

    _add_model_type(candidates, _image_model_type_from_component_indexes(root))""",
    ),
    (
        """    for model_type in (*local_model_types, _model_type_from_id(model)):
        model_class = _image_model_class_for_type(model_type)
        if model_class is not None and model_class.is_image_generation_model:
            return model_class
    return None""",
        """    for model_type in (_model_type_from_id(model), *local_model_types):
        model_class = _image_model_class_for_type(model_type)
        if model_class is not None and model_class.is_image_generation_model:
            return model_class
    return None""",
    ),
    (
        """    for model_type in (*local_model_types, _model_type_from_id(model)):
        model_class = _image_model_class_for_type(model_type)
        if model_class is not None and model_class.is_image_generation_model:
            break""",
        """    for model_type in (_model_type_from_id(model), *local_model_types):
        model_class = _image_model_class_for_type(model_type)
        if model_class is not None and model_class.is_image_generation_model:
            break""",
    ),
]

PATCH_MARKER = "# bonsai dispatch patch"


def find_image_py(resource_root: Path) -> Path:
    if resource_root.name == "image.py":
        return resource_root
    site_packages = sorted((resource_root / "python" / "lib").glob("python*/site-packages"))
    if not site_packages:
        raise SystemExit(f"No site-packages under {resource_root}")
    return site_packages[0] / "mlx_vlm" / "generate" / "image.py"


def apply_to(image_py: Path) -> bool:
    source = image_py.read_text()
    changed = False
    for old, new in REPLACEMENTS:
        if new in source:
            continue  # already applied
        if old not in source:
            raise SystemExit(
                f"{image_py} does not match the expected mlx-vlm source "
                "(pattern not found). mlx-vlm version drift? Rebaseline "
                "PythonDistribution/Scripts/patch_mlx_vlm_dispatch.py."
            )
        source = source.replace(old, new, 1)
        changed = True
    if changed:
        source = source.replace("# --- bonsai dispatch patch marker ---", "")
        source += f"\n# --- {PATCH_MARKER} ---\n"
        image_py.write_text(source)
    return changed


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <mlx-vlm-server-resource-root>")
    image_py = find_image_py(Path(sys.argv[1]).resolve())
    if apply_to(image_py):
        print(f"Patched {image_py}")
    else:
        print(f"Already patched {image_py}")


if __name__ == "__main__":
    main()
