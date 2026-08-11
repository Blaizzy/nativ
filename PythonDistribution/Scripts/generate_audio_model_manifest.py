#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
from types import ModuleType


MANIFEST_FILENAME = "audio-model-capabilities.json"


def _load_registry(site_packages: Path) -> ModuleType:
    registry_path = site_packages / "mlx_audio" / "registry.py"
    if not registry_path.is_file():
        raise FileNotFoundError(f"Missing mlx-audio registry: {registry_path}")

    spec = importlib.util.spec_from_file_location("nativ_mlx_audio_registry", registry_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load mlx-audio registry: {registry_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _classified_model_types(registry: ModuleType, kind: str) -> list[str]:
    candidates = registry.supported_model_types(kind)
    return sorted(
        model_type
        for model_type in candidates
        if registry.classify_model(model_type) == kind
    )


def generate_audio_model_manifest(site_packages: Path, output: Path) -> Path:
    registry = _load_registry(site_packages)
    speech_to_text = _classified_model_types(registry, "stt")
    text_to_speech = _classified_model_types(registry, "tts")
    if not speech_to_text or not text_to_speech:
        raise RuntimeError("mlx-audio did not expose both STT and TTS model types")

    manifest = {
        "schema_version": 1,
        "speech_to_text_model_types": speech_to_text,
        "text_to_speech_model_types": text_to_speech,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Describe the audio model types supported by bundled mlx-audio."
    )
    parser.add_argument("site_packages", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    generate_audio_model_manifest(
        args.site_packages.resolve(),
        args.output.resolve(),
    )


if __name__ == "__main__":
    main()
