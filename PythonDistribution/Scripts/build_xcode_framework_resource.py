#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DISTRIBUTION_ROOT = REPO_ROOT / "PythonDistribution"
DEFAULT_RESOURCE_NAME = "mlx-vlm-server"
MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def default_output() -> Path:
    target_build_dir = os.environ.get("TARGET_BUILD_DIR")
    wrapper_name = os.environ.get("WRAPPER_NAME")
    if not target_build_dir or not wrapper_name:
        raise SystemExit(
            "Pass an output path or run from an Xcode build phase with "
            "TARGET_BUILD_DIR and WRAPPER_NAME set."
        )
    return Path(target_build_dir) / wrapper_name / "Resources" / DEFAULT_RESOURCE_NAME


def default_mlx_vlm_source() -> Path | None:
    if os.environ.get("MLX_VLM_SOURCE_PATH"):
        return None

    source = REPO_ROOT.parent / "mlx-vlm"
    if not (source / "pyproject.toml").is_file() or not (source / "mlx_vlm").is_dir():
        return None

    branch = subprocess.run(
        ["git", "-C", str(source), "branch", "--show-current"],
        check=False,
        capture_output=True,
        text=True,
    )
    if branch.returncode != 0 or branch.stdout.strip() != "main":
        return None

    return source


def default_mlx_audio_source() -> Path | None:
    if os.environ.get("MLX_AUDIO_SOURCE_PATH"):
        return None

    source = REPO_ROOT.parent / "mlx-audio"
    if not (source / "pyproject.toml").is_file() or not (source / "mlx_audio").is_dir():
        return None

    branch = subprocess.run(
        ["git", "-C", str(source), "branch", "--show-current"],
        check=False,
        capture_output=True,
        text=True,
    )
    if branch.returncode != 0 or branch.stdout.strip() != "main":
        return None

    return source


def is_mach_o(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACH_O_MAGICS
    except OSError:
        return False


def sign_embedded_code(output: Path) -> None:
    if os.environ.get("CODE_SIGNING_ALLOWED") == "NO":
        print("Skipping embedded code signing because code signing is disabled.")
        return

    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or os.environ.get(
        "CODE_SIGN_IDENTITY"
    )
    if not identity:
        print("Skipping embedded code signing because no signing identity is available.")
        return

    mach_o_files = sorted(
        (path for path in output.rglob("*") if is_mach_o(path)),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    if not mach_o_files:
        raise SystemExit(f"No Mach-O files found in {output}")

    use_hardened_runtime = identity != "-"
    signing_mode = (
        "with Hardened Runtime"
        if use_hardened_runtime
        else "for local ad-hoc execution"
    )
    print(f"Signing {len(mach_o_files)} embedded Mach-O files {signing_mode}.")
    for path in mach_o_files:
        command = [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            identity,
        ]
        if use_hardened_runtime:
            command.extend(["--options", "runtime"])
        command.extend(["--timestamp=none", str(path)])
        subprocess.run(command, check=True)


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else default_output()
    output.parent.mkdir(parents=True, exist_ok=True)

    command = [
        sys.executable,
        str(PYTHON_DISTRIBUTION_ROOT / "Scripts" / "build_mlx_vlm_server.py"),
        "--output",
        str(output),
    ]
    mlx_vlm_source = default_mlx_vlm_source()
    if mlx_vlm_source is not None:
        print(f"Using local mlx-vlm source {mlx_vlm_source}")
        command.extend(["--mlx-vlm-source", str(mlx_vlm_source)])
    mlx_audio_source = default_mlx_audio_source()
    if mlx_audio_source is not None:
        print(f"Using local mlx-audio source {mlx_audio_source}")
        command.extend(["--mlx-audio-source", str(mlx_audio_source)])
    subprocess.run(command, cwd=REPO_ROOT, check=True)
    sign_embedded_code(output)


if __name__ == "__main__":
    main()
