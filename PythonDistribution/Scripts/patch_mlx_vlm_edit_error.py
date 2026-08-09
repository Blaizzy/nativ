#!/usr/bin/env python3
"""Patch mlx-vlm's image-edit error message so unsupported-edit failures explain why.

Root cause (stock mlx-vlm 0.6.10): requesting an image *edit* (reference
image) for a model without edit support raises

    ValueError(f"Image edit model {model} is not supported")

which reads as if the server does not know the model at all. Bonsai is a
text-to-image-only backend; only FLUX.2 and Mage-Flow-Edit models implement
image conditioning. The old message makes the real constraint invisible.

Fix (idempotent edit to mlx_vlm/generate/edit_image.py): explain that the
model is a generation-only model and that image editing requires a model
with edit support, naming the supported families.

Run from the build pipeline after pip install (alongside
patch_mlx_vlm_dispatch.py); also usable directly against a built server
resource (e.g. for a stale bundle).
"""

from __future__ import annotations

import sys
from pathlib import Path

# (old, new) exact-string replacements. `new` wins if already present
# (idempotent). A missing `old` raises so version drift is loud, not silent.
#
# ``long_form_unsupported`` is used both for the final fallback raise and for
# the authoritative-type guard; keeping the literal identical lets the patch
# stay idempotent across the two sites.
LONG_FORM_UNSUPPORTED = """    raise ValueError(
        "Model "
        + model
        + " is a text-to-image generation model and does not support "
        "image editing with reference images. Image editing requires a "
        "model that implements edit support (FLUX.2 or Mage-Flow-Edit). "
        "Send the request to /v1/images/generations without a reference "
        "image, or use an edit-capable model."
    )"""

REPLACEMENTS: list[tuple[str, str]] = [
    (
        '''    raise ValueError(f"Image edit model {model} is not supported")''',
        LONG_FORM_UNSUPPORTED,
    ),
    (
        """from .image import (
    DEFAULT_IMAGE_FORMAT,
    DEFAULT_IMAGE_GUIDANCE,
    DEFAULT_IMAGE_STEPS,
    ImageGenerationResult,
    _local_image_model_types,
    _model_type_from_id,
    _normalize_model_type,
    _resolve_image_model_path,
)""",
        """from .image import (
    DEFAULT_IMAGE_FORMAT,
    DEFAULT_IMAGE_GUIDANCE,
    DEFAULT_IMAGE_STEPS,
    ImageGenerationResult,
    _image_model_class_for_type,
    _image_model_type_from_manifest,
    _load_json_file,
    _local_image_model_types,
    _model_type_from_id,
    _normalize_model_type,
    _resolve_image_model_path,
)""",
    ),
    (
        """    local_model_types = (
        _local_image_model_types(str(resolved_path))
        if resolved_path is not None
        else ()
    )
    model_class = None""",
        """    local_model_types = (
        _local_image_model_types(str(resolved_path))
        if resolved_path is not None
        else ()
    )
    # If the repo's authoritative type (manifest first, then model id) maps
    # to a known image model that has no edit-capable class, stop here:
    # Bonsai repos carry FLUX.2-named components, so the candidate scan
    # below would otherwise select the flux2 edit class and fail variant
    # inference on Bonsai weights. Raise the clear unsupported-edit message
    # instead of the confusing flux2 variant error. (A type with an edit
    # class, e.g. flux2 or mage_flow, skips the guard and keeps today's
    # behavior.)
    authoritative_type = _model_type_from_id(model)
    if resolved_path is not None:
        manifest = _load_json_file(Path(resolved_path) / "manifest.json")
        if manifest is not None:
            authoritative_type = (
                _image_model_type_from_manifest(manifest) or authoritative_type
            )
    if _image_edit_model_class_for_type(authoritative_type) is None and (
        _image_model_class_for_type(authoritative_type) is not None
    ):
        raise ValueError(
            "Model "
            + model
            + " is a text-to-image generation model and does not support "
            "image editing with reference images. Image editing requires a "
            "model that implements edit support (FLUX.2 or Mage-Flow-Edit). "
            "Send the request to /v1/images/generations without a reference "
            "image, or use an edit-capable model."
        )
    model_class = None""",
    ),
]

PATCH_MARKER = "# bonsai edit-error patch"


def find_edit_image_py(resource_root: Path) -> Path:
    if resource_root.name == "edit_image.py":
        return resource_root
    site_packages = sorted((resource_root / "python" / "lib").glob("python*/site-packages"))
    if not site_packages:
        raise SystemExit(f"No site-packages under {resource_root}")
    return site_packages[0] / "mlx_vlm" / "generate" / "edit_image.py"


def apply_to(edit_image_py: Path) -> bool:
    source = edit_image_py.read_text()
    changed = False
    for old, new in REPLACEMENTS:
        if new in source:
            continue  # already applied
        if old not in source:
            raise SystemExit(
                f"{edit_image_py} does not match the expected mlx-vlm source "
                "(pattern not found). mlx-vlm version drift? Rebaseline "
                "PythonDistribution/Scripts/patch_mlx_vlm_edit_error.py."
            )
        source = source.replace(old, new, 1)
        changed = True
    if changed:
        source = source.replace("# --- bonsai edit-error patch marker ---", "")
        source += f"\n# --- {PATCH_MARKER} ---\n"
        edit_image_py.write_text(source)
    return changed


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <mlx-vlm-server-resource-root>")
    edit_image_py = find_edit_image_py(Path(sys.argv[1]).resolve())
    if apply_to(edit_image_py):
        print(f"Patched {edit_image_py}")
    else:
        print(f"Already patched {edit_image_py}")


if __name__ == "__main__":
    main()
