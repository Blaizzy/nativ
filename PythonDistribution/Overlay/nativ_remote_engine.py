"""Forward chosen models to an external OpenAI-compatible engine, such as Splash.

Nativ's server stays the single front door for the app, so metrics, scheduled tasks and settings
keep working. Models listed in the engines file are answered by the external engine instead of
being loaded in-process.

The engines file maps a Nativ model id to its engine:

    {"local/Qwen3.8-27B-Uncensored-4bit":
        {"base_url": "http://127.0.0.1:8091/v1", "model": "local/Qwen3.8-27B-Uncensored-4bit"}}
"""
from __future__ import annotations

import json
import logging
import os
from typing import Any

import httpx
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.background import BackgroundTask

log = logging.getLogger("nativ.remote_engine")

ENGINES_PATH = os.path.expanduser("~/Library/Application Support/Nativ/remote-engines.json")
# Paths an external engine answers. Compaction is run by Nativ's own runtime, so it is not forwarded.
FORWARDED_PATHS = {"/chat/completions": "/chat/completions", "/responses": "/responses"}
HOP_HEADERS = frozenset({"host", "content-length", "connection", "transfer-encoding", "keep-alive", "date", "server"})
CONNECT_TIMEOUT_S = 10

_client: httpx.AsyncClient | None = None


def load_engines(path: str = ENGINES_PATH) -> dict[str, dict[str, str]]:
    """Read the model-to-engine map. A missing or unreadable file means no remote engines."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        log.warning("remote engines file unreadable: %s", error)
        return {}
    return {
        model: engine
        for model, engine in data.items()
        if isinstance(engine, dict) and isinstance(engine.get("base_url"), str)
    }


def engine_for(payload: Any, engines: dict[str, dict[str, str]]) -> dict[str, str] | None:
    """Return the engine that serves the request's model, or None to serve it in-process."""
    if not isinstance(payload, dict):
        return None
    model = payload.get("model")
    return engines.get(model) if isinstance(model, str) else None


def upstream_path(request_path: str) -> str | None:
    """Map Nativ's route (with or without the /v1 prefix) to the engine's path, or None if not forwarded."""
    bare = request_path[3:] if request_path.startswith("/v1/") else request_path
    return FORWARDED_PATHS.get(bare)


def _http_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=CONNECT_TIMEOUT_S))
    return _client


async def forward(request: Any, payload: dict[str, Any], engine: dict[str, str]) -> Response:
    """Send the request to the external engine and return its answer, streaming included."""
    path = upstream_path(request.url.path)
    if path is None:
        return JSONResponse(
            {"error": {"message": f"{request.url.path} is not available for externally served models",
                       "type": "not_implemented"}},
            status_code=501,
        )
    body = dict(payload)
    body["model"] = engine.get("model", payload["model"])
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_HEADERS and k.lower() != "authorization"}
    if engine.get("api_key"):
        headers["authorization"] = f"Bearer {engine['api_key']}"
    client = _http_client()
    upstream = client.build_request("POST", engine["base_url"].rstrip("/") + path, headers=headers, json=body)
    try:
        response = await client.send(upstream, stream=True)
    except httpx.HTTPError as error:
        log.warning("remote engine unreachable: %s", error)
        return JSONResponse(
            {"error": {"message": f"external engine unreachable: {error}", "type": "engine_unavailable"}},
            status_code=503,
        )
    passthrough = {k: v for k, v in response.headers.items() if k.lower() not in HOP_HEADERS}
    media_type = response.headers.get("content-type", "")
    if "text/event-stream" in media_type:
        return StreamingResponse(response.aiter_raw(), status_code=response.status_code,
                                 headers=passthrough, background=BackgroundTask(response.aclose))
    content = await response.aread()
    await response.aclose()
    return Response(content, status_code=response.status_code, headers=passthrough)
