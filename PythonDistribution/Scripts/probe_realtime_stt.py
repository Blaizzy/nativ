#!/usr/bin/env python3
"""Probe live STT through an isolated Nativ Python overlay and loopback socket.

Requires candidate mlx-vlm/mlx-audio packages in the selected interpreter.
Never modifies the installed application or its analytics database.
"""

import argparse
import base64
import json
import os
import socket
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from urllib.parse import quote


def probe(ws, pcm):
    created = json.loads(ws.recv(timeout=120))
    if created.get("type") != "session.created":
        raise RuntimeError(f"Session creation failed: {created}")
    if created["session"]["input_audio_sample_rate"] != 16000:
        raise ValueError("This probe requires a 16 kHz model")
    timing = {"start": time.monotonic()}
    failures = []
    stop = threading.Event()

    def send():
        try:
            for offset in range(0, len(pcm), 640):
                if stop.is_set():
                    return
                ws.send(
                    json.dumps(
                        {
                            "type": "input_audio_buffer.append",
                            "audio": base64.b64encode(
                                pcm[offset : offset + 640]
                            ).decode(),
                        }
                    )
                )
                stop.wait(0.02)
            timing["commit"] = time.monotonic()
            ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
        except Exception as exc:
            failures.append(str(exc))

    sender = threading.Thread(target=send, daemon=True)
    sender.start()
    first = None
    partial_before_commit = False
    try:
        while True:
            message = json.loads(ws.recv(timeout=120))
            if message["type"] == "error":
                raise RuntimeError(message["error"])
            if message["type"].endswith(".delta") and first is None:
                first = time.monotonic()
                partial_before_commit = "commit" not in timing
            if message["type"].endswith(".completed"):
                finished = time.monotonic()
                break
        if failures or not partial_before_commit or "commit" not in timing:
            raise RuntimeError(f"Live partial/final proof failed: {failures}")
        return {
            "first_partial_s": round(first - timing["start"], 3),
            "commit_to_final_s": round(finished - timing["commit"], 3),
            "partial_before_commit": partial_before_commit,
            "transcript": message["transcript"],
            "audio_s": len(pcm) / 32000,
        }
    finally:
        stop.set()
        ws.close()
        sender.join(5)
        if sender.is_alive():
            raise RuntimeError("Audio sender did not stop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        required=True,
        type=Path,
        help="Existing local model snapshot; no download",
    )
    parser.add_argument(
        "--wav",
        required=True,
        action="append",
        type=Path,
        help="Synthetic mono PCM16 16 kHz WAV; repeat for more fixtures",
    )
    args = parser.parse_args()
    model = args.model.resolve(strict=True)
    fixtures = []
    for path in args.wav:
        with wave.open(str(path)) as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (
                16000,
                1,
                2,
            ):
                parser.error("Fixtures must be mono PCM16 at 16000 Hz")
            fixtures.append((path.name, wav.readframes(wav.getnframes())))

    # These overrides apply only to this disposable process, before import.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["MLX_PLATFORM_ANALYTICS_DB_PATH"] = str(
        Path(tempfile.mkdtemp(prefix="nativ-stt-proof-")) / "analytics.sqlite3"
    )
    os.environ.pop("MLX_VLM_SERVER_API_KEY", None)
    for key in tuple(os.environ):
        if key.startswith("MLX_VLM_PRELOAD_"):
            os.environ.pop(key)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Overlay"))
    import nativ_server
    import uvicorn
    from websockets.sync.client import connect

    route = "/v1/audio/transcriptions/realtime"
    if not any(
        getattr(item, "path", None) == route for item in nativ_server.base.app.routes
    ):
        raise RuntimeError(
            "Installed mlx-vlm lacks the live STT route; install candidate dependencies first"
        )
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(
            nativ_server.base.app,
            log_level="warning",
            ws_max_size=128 * 1024,
            ws_max_queue=64,
        )
    )
    thread = threading.Thread(
        target=server.run, kwargs={"sockets": [sock]}, daemon=True
    )
    thread.start()
    try:
        deadline = time.monotonic() + 30
        while not server.started:
            if not thread.is_alive() or time.monotonic() > deadline:
                raise RuntimeError("Nativ overlay failed to start")
            time.sleep(0.05)
        for name, pcm in fixtures:
            with connect(
                f"ws://127.0.0.1:{port}{route}?model={quote(str(model), safe='')}"
            ) as ws:
                print(json.dumps({"fixture": name, **probe(ws, pcm)}), flush=True)
    finally:
        server.should_exit = True
        thread.join(30)
        sock.close()
        if thread.is_alive():
            raise RuntimeError("Nativ overlay failed to stop")


if __name__ == "__main__":
    main()
