#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from urllib.parse import quote
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from generate_image_model_manifest import (
    MANIFEST_FILENAME as IMAGE_MODEL_MANIFEST_FILENAME,
)
from generate_image_model_manifest import generate_image_model_manifest


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DISTRIBUTION_ROOT = REPO_ROOT / "PythonDistribution"
LAUNCHER_SOURCE = PYTHON_DISTRIBUTION_ROOT / "Launcher" / "mlx_vlm_server_launcher.c"
OVERLAY_SERVER = PYTHON_DISTRIBUTION_ROOT / "Overlay" / "nativ_server.py"
IMAGE_MODEL_MANIFEST_GENERATOR = Path(__file__).with_name(
    "generate_image_model_manifest.py"
)
DEFAULT_PYTHON_VERSION = "3.12.13"
DEFAULT_PBS_RELEASE = "20260508"
DEFAULT_PBS_ASSET = (
    "cpython-3.12.13+20260508-aarch64-apple-darwin-install_only_stripped.tar.gz"
)
DEFAULT_REQUIREMENTS = (
    PYTHON_DISTRIBUTION_ROOT
    / "Requirements"
    / "mlx-vlm-server-macos-arm64.txt"
)
DEFAULT_OUTPUT = REPO_ROOT / "dist" / "mlx-vlm-server"
DEFAULT_CACHE = REPO_ROOT / ".cache" / "python-build-standalone"
BUILD_STAMP = ".mlx-vlm-server-build.json"
LATEST_RELEASE_JSON = (
    "https://raw.githubusercontent.com/astral-sh/python-build-standalone/"
    "latest-release/latest-release.json"
)
GITHUB_RELEASE_API = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/{tag}"
GITHUB_RELEASE_DOWNLOAD = (
    "https://github.com/astral-sh/python-build-standalone/releases/download/{tag}/{asset}"
)


@dataclass(frozen=True)
class Asset:
    name: str
    url: str


def log(message: str) -> None:
    print(f"==> {message}", flush=True)


def fetch_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "nativ-builder"})
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def resolve_release_tag(release: str) -> str:
    if release != "latest":
        return release

    metadata = fetch_json(LATEST_RELEASE_JSON)
    return metadata["tag"]


def host_target_triple() -> str:
    system = platform.system()
    machine = platform.machine().lower()

    if system == "Darwin":
        if machine in {"arm64", "aarch64"}:
            return "aarch64-apple-darwin"
        if machine in {"x86_64", "amd64"}:
            return "x86_64-apple-darwin"
    if system == "Linux":
        if machine in {"x86_64", "amd64"}:
            return "x86_64-unknown-linux-gnu"
        if machine in {"arm64", "aarch64"}:
            return "aarch64-unknown-linux-gnu"
    if system == "Windows":
        if machine in {"x86_64", "amd64"}:
            return "x86_64-pc-windows-msvc"
        if machine in {"arm64", "aarch64"}:
            return "aarch64-pc-windows-msvc"

    raise SystemExit(f"Unsupported host platform: {system} {platform.machine()}")


def version_key(name: str) -> tuple[int, ...]:
    match = re.search(r"^cpython-(\d+)\.(\d+)\.(\d+)", name)
    if not match:
        return ()
    return tuple(int(part) for part in match.groups())


def release_assets(tag: str) -> list[Asset]:
    data = fetch_json(GITHUB_RELEASE_API.format(tag=tag))
    return [Asset(name=asset["name"], url=asset["browser_download_url"]) for asset in data["assets"]]


def asset_from_name(tag: str, name: str) -> Asset:
    return Asset(
        name=name,
        url=GITHUB_RELEASE_DOWNLOAD.format(tag=quote(tag), asset=quote(name)),
    )


def select_asset(
    assets: Iterable[Asset],
    *,
    python_version: str,
    target: str,
    stripped: bool,
) -> Asset:
    escaped_version = re.escape(python_version)
    flavor = "install_only_stripped" if stripped else "install_only"
    pattern = re.compile(
        rf"^cpython-{escaped_version}(?:\.\d+(?:[a-z0-9.]*)?)?\+\d+-"
        rf"{re.escape(target)}-{flavor}\.tar\.(?:gz|zst|zstd)$"
    )
    candidates = [
        asset
        for asset in assets
        if pattern.match(asset.name)
        and "freethreaded" not in asset.name
        and "debug" not in asset.name
    ]

    if not candidates and stripped:
        return select_asset(
            assets,
            python_version=python_version,
            target=target,
            stripped=False,
        )

    if not candidates:
        raise SystemExit(
            f"No python-build-standalone asset found for Python {python_version} on {target}"
        )

    return sorted(candidates, key=lambda asset: version_key(asset.name))[-1]


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        log(f"Using cached {destination.name}")
        return

    log(f"Downloading {url}")
    tmp = destination.with_suffix(destination.suffix + ".tmp")
    request = urllib.request.Request(url, headers={"User-Agent": "nativ-builder"})
    with urllib.request.urlopen(request) as response, tmp.open("wb") as handle:
        shutil.copyfileobj(response, handle)
    tmp.replace(destination)


def safe_extract_tar(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)

    if archive.name.endswith((".tar.zst", ".tar.zstd")):
        if shutil.which("tar") is None:
            raise SystemExit("A tar executable is required to extract zstd archives")
        subprocess.run(["tar", "-xf", str(archive), "-C", str(destination)], check=True)
        return

    with tarfile.open(archive) as tar:
        if sys.version_info >= (3, 12):
            tar.extractall(destination, filter="data")
        else:
            tar.extractall(destination)


def find_install_root(extracted: Path) -> Path:
    candidates = [extracted / "python" / "install", extracted / "install"]
    for candidate in candidates:
        if python_executable(candidate).exists():
            return candidate

    for candidate in extracted.rglob("bin/python3"):
        return candidate.parents[1]

    raise SystemExit(f"Could not locate Python install root under {extracted}")


def python_executable(prefix: Path) -> Path:
    if os.name == "nt":
        return prefix / "python.exe"
    return prefix / "bin" / "python3"


def run(command: list[str], *, env: dict[str, str] | None = None) -> None:
    log(" ".join(command))
    subprocess.run(command, check=True, env=env)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_or_absolute(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def git_output(cwd: Path, args: list[str]) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(cwd), *args],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def validate_mlx_vlm_source(path: Path) -> Path:
    source = path.resolve()
    if not (source / "pyproject.toml").exists():
        raise SystemExit(f"Missing pyproject.toml in local mlx-vlm source: {source}")
    if not (source / "mlx_vlm").exists():
        raise SystemExit(f"Missing mlx_vlm package in local mlx-vlm source: {source}")
    return source


def build_signature(
    *,
    asset: Asset,
    python_version: str,
    pbs_release: str,
    target: str,
    requirements: Path | None,
    mlx_vlm_source: Path | None,
    skip_install: bool,
) -> dict[str, object]:
    return {
        "version": 4,
        "asset": asset.name,
        "python_version": python_version,
        "pbs_release": pbs_release,
        "target": target,
        "requirements": str(requirements.relative_to(REPO_ROOT)) if requirements else None,
        "requirements_sha256": file_sha256(requirements) if requirements else None,
        "mlx_vlm_source": relative_or_absolute(mlx_vlm_source) if mlx_vlm_source else None,
        "mlx_vlm_source_branch": (
            git_output(mlx_vlm_source, ["branch", "--show-current"])
            if mlx_vlm_source
            else None
        ),
        "mlx_vlm_source_head": (
            git_output(mlx_vlm_source, ["rev-parse", "HEAD"])
            if mlx_vlm_source
            else None
        ),
        "mlx_vlm_source_status": (
            git_output(mlx_vlm_source, ["status", "--short", "--untracked-files=no"])
            if mlx_vlm_source
            else None
        ),
        "launcher_sha256": file_sha256(LAUNCHER_SOURCE),
        "overlay_server_sha256": file_sha256(OVERLAY_SERVER),
        "image_model_manifest_generator_sha256": file_sha256(
            IMAGE_MODEL_MANIFEST_GENERATOR
        ),
        "builder_sha256": file_sha256(Path(__file__)),
        "skip_install": skip_install,
    }


def read_stamp(output: Path) -> dict[str, object] | None:
    stamp = output / BUILD_STAMP
    if not stamp.exists():
        return None
    try:
        return json.loads(stamp.read_text())
    except json.JSONDecodeError:
        return None


def write_stamp(output: Path, signature: dict[str, object]) -> None:
    (output / BUILD_STAMP).write_text(
        json.dumps(signature, indent=2, sort_keys=True) + "\n"
    )


def has_valid_stamp(output: Path, signature: dict[str, object]) -> bool:
    return read_stamp(output) == signature


def install_python(asset: Asset, cache_dir: Path, output: Path, force: bool) -> Path:
    archive = cache_dir / asset.name
    download(asset.url, archive)

    python_dir = output / "python"
    if python_dir.exists() and not force:
        log(f"Using existing Python at {python_dir}")
        return python_dir

    if python_dir.exists():
        shutil.rmtree(python_dir)

    with tempfile.TemporaryDirectory(prefix="pbs-", dir=str(REPO_ROOT / "build")) as tmp_name:
        extracted = Path(tmp_name)
        log(f"Extracting {archive.name}")
        safe_extract_tar(archive, extracted)
        install_root = find_install_root(extracted)
        shutil.copytree(install_root, python_dir, symlinks=True)

    return python_dir


def launcher_contents() -> str:
    return """#!/usr/bin/env bash
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"
  SELF="$(readlink "$SELF")"
  case "$SELF" in
    /*) ;;
    *) SELF="$DIR/$SELF" ;;
  esac
done

BIN_DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd "$BIN_DIR/.." >/dev/null 2>&1 && pwd)"

export PYTHONHOME="$ROOT_DIR/python"
export PYTHONNOUSERSITE=1

PARENT_PID="$PPID"
LAUNCHER_PID="$$"
"$ROOT_DIR/python/bin/python3" -m nativ_server "$@" &
CHILD_PID="$!"

request_child_shutdown() {
  kill -TERM "$CHILD_PID" >/dev/null 2>&1 || true
  (
    sleep 3
    kill -KILL "$CHILD_PID" >/dev/null 2>&1 || true
  ) &
}

terminate_child() {
  local signal_name="$1"
  kill "-$signal_name" "$CHILD_PID" >/dev/null 2>&1 || true
  (
    sleep 3
    kill -KILL "$CHILD_PID" >/dev/null 2>&1 || true
  ) &
  local killer_pid="$!"

  set +e
  wait "$CHILD_PID"
  local status="$?"
  set -e

  kill "$killer_pid" >/dev/null 2>&1 || true
  exit "$status"
}

monitor_parent() {
  while kill -0 "$CHILD_PID" >/dev/null 2>&1; do
    local current_parent
    current_parent="$(ps -o ppid= -p "$LAUNCHER_PID" 2>/dev/null | tr -d ' ')"
    if [[ -z "$current_parent" || "$current_parent" != "$PARENT_PID" ]]; then
      request_child_shutdown
      exit 0
    fi
    sleep 0.1
  done
}

monitor_parent &
MONITOR_PID="$!"

cleanup_monitor() {
  kill "$MONITOR_PID" >/dev/null 2>&1 || true
}

trap cleanup_monitor EXIT
trap 'terminate_child TERM' TERM
trap 'terminate_child INT' INT
trap 'terminate_child HUP' HUP
trap 'terminate_child QUIT' QUIT

set +e
wait "$CHILD_PID"
STATUS="$?"
set -e

exit "$STATUS"
"""


def write_launcher(output: Path) -> Path:
    launcher = output / "bin" / "mlx-vlm-server"
    launcher.write_text(launcher_contents())
    launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return launcher


def build_native_launcher(output: Path) -> Path | None:
    compiler = shutil.which("cc")
    if compiler is None or os.name == "nt":
        return None

    launcher = output / "bin" / "mlx-vlm-server"
    run(
        [
            compiler,
            "-O2",
            "-Wall",
            "-Wextra",
            "-o",
            str(launcher),
            str(LAUNCHER_SOURCE),
        ]
    )
    return launcher


def write_or_build_launcher(output: Path) -> Path:
    launcher = build_native_launcher(output)
    if launcher is not None:
        return launcher
    log("No supported C compiler found; writing shell launcher")
    return write_launcher(output)


def install_mlx_vlm(
    python: Path,
    *,
    mlx_vlm_version: str | None,
    extra_pip_args: list[str],
) -> None:
    package = "mlx-vlm"
    if mlx_vlm_version:
        package = f"{package}=={mlx_vlm_version}"

    env = os.environ.copy()
    env["PYTHONNOUSERSITE"] = "1"

    run([str(python), "-m", "pip", "install", "--upgrade", "pip"], env=env)
    run(
        [str(python), "-m", "pip", "install", "--no-cache-dir", package, *extra_pip_args],
        env=env,
    )


def install_requirements(
    python: Path,
    *,
    requirements: Path,
    extra_pip_args: list[str],
) -> None:
    if not requirements.exists():
        raise SystemExit(f"Missing requirements file: {requirements}")

    env = os.environ.copy()
    env["PYTHONNOUSERSITE"] = "1"

    run(
        [
            str(python),
            "-m",
            "pip",
            "install",
            "--only-binary=:all:",
            "-r",
            str(requirements),
            *extra_pip_args,
        ],
        env=env,
    )


def install_local_mlx_vlm(
    python: Path,
    *,
    source: Path,
    extra_pip_args: list[str],
) -> None:
    env = os.environ.copy()
    env["PYTHONNOUSERSITE"] = "1"

    log(f"Installing mlx-vlm from local source {source}")
    run(
        [
            str(python),
            "-m",
            "pip",
            "install",
            "--upgrade",
            "pip",
            "setuptools",
            "wheel",
        ],
        env=env,
    )
    run(
        [
            str(python),
            "-m",
            "pip",
            "install",
            "--no-deps",
            "--force-reinstall",
            "--no-build-isolation",
            str(source),
            *extra_pip_args,
        ],
        env=env,
    )


def site_packages_dir(output: Path) -> Path:
    matches = sorted((output / "python" / "lib").glob("python*/site-packages"))
    if not matches:
        raise SystemExit(f"Could not locate site-packages under {output / 'python' / 'lib'}")
    return matches[0]


def install_overlay(output: Path) -> None:
    destination = site_packages_dir(output) / OVERLAY_SERVER.name
    log(f"Installing metrics overlay {OVERLAY_SERVER.name}")
    shutil.copy2(OVERLAY_SERVER, destination)


def install_image_model_manifest(output: Path) -> None:
    destination = output / IMAGE_MODEL_MANIFEST_FILENAME
    log(f"Generating image model capability manifest {destination.name}")
    generate_image_model_manifest(site_packages_dir(output), destination)


def verify_distribution(output: Path, *, expect_mlx_vlm: bool) -> None:
    python = python_executable(output / "python")
    launcher = output / "bin" / "mlx-vlm-server"

    run([str(python), "-c", "import sys; print(sys.version)"])
    if expect_mlx_vlm:
        run(
            [
                str(python),
                "-c",
                "import importlib.util; "
                "raise SystemExit(0 if importlib.util.find_spec('mlx_vlm.server') else 1)",
            ]
        )
        run(
            [
                str(python),
                "-c",
                "import importlib.util; "
                "raise SystemExit(0 if importlib.util.find_spec('nativ_server') else 1)",
            ]
        )
        manifest_path = output / IMAGE_MODEL_MANIFEST_FILENAME
        if not manifest_path.exists():
            raise SystemExit(f"Missing image model capability manifest: {manifest_path}")
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise SystemExit(
                f"Invalid image model capability manifest: {manifest_path}: {error}"
            ) from error
        if (
            manifest.get("schema_version") != 1
            or not isinstance(manifest.get("model_types"), list)
            or not manifest["model_types"]
        ):
            raise SystemExit(
                f"Invalid image model capability manifest contents: {manifest_path}"
            )
    if not launcher.exists():
        raise SystemExit(f"Missing launcher: {launcher}")


def parse_args() -> argparse.Namespace:
    default_mlx_vlm_source = os.environ.get("MLX_VLM_SOURCE_PATH")
    parser = argparse.ArgumentParser(
        description="Build a relocatable mlx-vlm server distribution with python-build-standalone."
    )
    parser.add_argument(
        "--python-version",
        default=DEFAULT_PYTHON_VERSION,
        help="CPython version to use",
    )
    parser.add_argument(
        "--pbs-release",
        default=DEFAULT_PBS_RELEASE,
        help="python-build-standalone tag or latest",
    )
    parser.add_argument(
        "--pbs-asset",
        default=DEFAULT_PBS_ASSET,
        help="Exact python-build-standalone asset name, or auto to query GitHub releases",
    )
    parser.add_argument(
        "--target",
        default=None,
        help="Override python-build-standalone target triple",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Output directory",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=DEFAULT_CACHE,
        help="Download cache directory",
    )
    parser.add_argument(
        "--requirements",
        type=Path,
        default=DEFAULT_REQUIREMENTS,
        help="Pinned requirements file to install into the standalone Python",
    )
    parser.add_argument(
        "--no-requirements",
        action="store_true",
        help="Install mlx-vlm directly instead of using the pinned requirements file",
    )
    parser.add_argument(
        "--mlx-vlm-version",
        default=None,
        help="Pin mlx-vlm to an exact version",
    )
    parser.add_argument(
        "--mlx-vlm-source",
        type=Path,
        default=Path(default_mlx_vlm_source) if default_mlx_vlm_source else None,
        help="Install mlx-vlm from a local source checkout after installing dependencies",
    )
    parser.add_argument(
        "--pip-arg",
        action="append",
        default=[],
        help="Extra argument to pass through to pip install mlx-vlm",
    )
    parser.add_argument(
        "--skip-install",
        action="store_true",
        help="Do not install mlx-vlm",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Only verify an existing output tree",
    )
    parser.add_argument("--force", action="store_true", help="Rebuild even if output exists")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output = args.output.resolve()

    if args.verify_only:
        verify_distribution(output, expect_mlx_vlm=not args.skip_install)
        return

    (REPO_ROOT / "build").mkdir(exist_ok=True)
    tag = resolve_release_tag(args.pbs_release)
    target = args.target or host_target_triple()
    log(f"Using python-build-standalone release {tag} for {target}")

    if args.pbs_asset == "auto":
        asset = select_asset(
            release_assets(tag),
            python_version=args.python_version,
            target=target,
            stripped=True,
        )
    else:
        asset = asset_from_name(tag, args.pbs_asset)
    log(f"Selected {asset.name}")

    requirements = (
        None if args.skip_install or args.no_requirements else args.requirements.resolve()
    )
    mlx_vlm_source = (
        validate_mlx_vlm_source(args.mlx_vlm_source)
        if args.mlx_vlm_source and not args.skip_install
        else None
    )
    signature = build_signature(
        asset=asset,
        python_version=args.python_version,
        pbs_release=tag,
        target=target,
        requirements=requirements,
        mlx_vlm_source=mlx_vlm_source,
        skip_install=args.skip_install,
    )

    if output.exists() and not args.force and has_valid_stamp(output, signature):
        log(f"Using existing stamped build at {output}")
        verify_distribution(output, expect_mlx_vlm=not args.skip_install)
        return

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "bin").mkdir(exist_ok=True)

    python_dir = install_python(asset, args.cache_dir.resolve(), output, force=True)
    python = python_executable(python_dir)

    if not args.skip_install:
        if requirements:
            install_requirements(python, requirements=requirements, extra_pip_args=args.pip_arg)
        else:
            install_mlx_vlm(
                python,
                mlx_vlm_version=args.mlx_vlm_version,
                extra_pip_args=args.pip_arg,
            )
        if mlx_vlm_source:
            install_local_mlx_vlm(
                python,
                source=mlx_vlm_source,
                extra_pip_args=args.pip_arg,
            )
        install_overlay(output)
        install_image_model_manifest(output)

    launcher = write_or_build_launcher(output)
    verify_distribution(output, expect_mlx_vlm=not args.skip_install)
    write_stamp(output, signature)

    log(f"Built {output}")
    log(f"Launcher: {launcher}")


if __name__ == "__main__":
    main()
