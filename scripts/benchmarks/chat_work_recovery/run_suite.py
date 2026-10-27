#!/usr/bin/env python3
"""Run on one Apple Silicon host, serializing every model workload."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-binary", required=True)
    parser.add_argument("--recovery-binary", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18985)
    parser.add_argument("--contexts", nargs="+", type=int, default=[8192, 16384])
    parser.add_argument("--cases", nargs="+", choices=["chain", "catalog", "live"])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--modes", nargs="+", choices=["baseline", "recovery"], default=["baseline", "recovery"])
    parser.add_argument("--max-output-tokens", type=int, default=4096)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    hardware = json.loads(subprocess.check_output(["system_profiler", "SPHardwareDataType", "-json"], text=True))["SPHardwareDataType"][0]
    environment = {"hardware": {key: hardware[key] for key in ["machine_name", "machine_model", "chip_type", "number_processors", "physical_memory"] if key in hardware},
                   "os": platform.platform(), "python": sys.version,
                   "packages": {p: importlib.metadata.version(p) for p in ["mlx", "mlx-vlm", "transformers"]},
                   "settings": {"prefix_cache": True, "disk_cache": False, "thinking": False, "temperature": 0, "max_output_tokens": args.max_output_tokens}}
    (args.output / "environment.json").write_text(json.dumps(environment, indent=2))
    base = f"http://127.0.0.1:{args.port}"
    for context in args.contexts:
        log = open(args.output / f"runtime-{context}.log", "w")
        proc = subprocess.Popen([sys.executable, "-m", "mlx_vlm.server", "--host", "127.0.0.1",
                                 "--port", str(args.port), "--max-kv-size", str(context)], stdout=log, stderr=log,
                                env={**os.environ, "APC_ENABLED": "1", "APC_DISK_ENABLED": "0",
                                     "HF_HUB_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false"})
        try:
            for _ in range(150):
                if proc.poll() is not None:
                    raise RuntimeError("Runtime exited; check log")
                try:
                    with urllib.request.urlopen(base + "/health", timeout=1) as response:
                        assert json.load(response)["effective_context_limit"] == context
                    break
                except Exception:
                    time.sleep(.2)
            else:
                raise RuntimeError("Runtime did not become ready")
            for rep in range(args.repetitions):
                modes = args.modes if rep != 1 else list(reversed(args.modes))
                cases = args.cases or (["chain", "catalog", "live"] if context == 8192 else ["chain", "catalog"])
                for case in cases:
                    for mode in modes:
                        label = f"{case}-{context}-{mode}-{rep}"
                        print("START", label, flush=True)
                        status = subprocess.run([sys.executable, "-u", str(Path(__file__).with_name("benchmark.py")),
                            "--binary", args.baseline_binary if mode == "baseline" else args.recovery_binary, "--base", base, "--model", args.model,
                            "--mode", mode, "--case", case, "--context", str(context),
                            "--seed", str(123 + rep), "--max-output-tokens", str(args.max_output_tokens), "--max-rounds", "33",
                            "--output", str(args.output / label)], timeout=2100).returncode
                        print("END", label, "status", status, flush=True)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log.close()


if __name__ == "__main__":
    main()
