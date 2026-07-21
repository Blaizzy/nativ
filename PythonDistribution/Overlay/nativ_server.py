from __future__ import annotations

import atexit
import json
import logging
import os
import sqlite3
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime
from threading import Lock
from types import SimpleNamespace
from typing import Any

from fastapi import HTTPException, Request
from fastapi.responses import Response

import mlx_vlm.server as base
import mlx_vlm.server.cli as base_cli
import mlx_vlm.server.openai as base_openai


BACKEND_NAME = f"mlx_vlm/{base.__version__}"
TRACKED_PATHS = {
    "/chat/completions",
    "/v1/chat/completions",
    "/responses",
    "/v1/responses",
}
METRICS_PATHS = {"/metrics", "/v1/metrics"}

_BASE_METRICS_CAPTURE: ContextVar[dict[str, Any] | None] = ContextVar(
    "nativ_base_metrics_capture",
    default=None,
)


class MetricsAccessLogFilter(logging.Filter):
    """Hide successful metrics polls from Uvicorn's access log."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if not isinstance(args, tuple) or len(args) < 5:
            return True

        request_path = str(args[2]).partition("?")[0]
        try:
            status_code = int(args[4])
        except (TypeError, ValueError):
            return True

        return request_path not in METRICS_PATHS or status_code >= 400


def install_metrics_access_log_filter() -> None:
    access_logger = logging.getLogger("uvicorn.access")
    if any(isinstance(item, MetricsAccessLogFilter) for item in access_logger.filters):
        return
    access_logger.addFilter(MetricsAccessLogFilter())


@dataclass
class RequestObservation:
    request_id: str
    endpoint: str
    model: str | None
    stream: bool
    image_count: int
    audio_count: int
    structured_output: bool
    thinking_enabled: bool
    started_at_unix: float
    start_time: float
    first_token_at: float | None = None


@dataclass
class ModelAggregate:
    model: str
    requests_started: int = 0
    requests_completed: int = 0
    requests_failed: int = 0
    streaming_requests: int = 0
    prompt_tokens_total: int = 0
    completion_tokens_total: int = 0
    generated_tokens_total: int = 0
    request_time_total_seconds: float = 0.0
    decode_time_total_seconds: float = 0.0
    last_request_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        avg_request_tok_s = (
            self.completion_tokens_total / self.request_time_total_seconds
            if self.request_time_total_seconds > 0
            else 0.0
        )
        avg_decode_tok_s = (
            self.generated_tokens_total / self.decode_time_total_seconds
            if self.decode_time_total_seconds > 0
            else 0.0
        )
        return {
            "model": self.model,
            "requests_started": self.requests_started,
            "requests_completed": self.requests_completed,
            "requests_failed": self.requests_failed,
            "streaming_requests": self.streaming_requests,
            "prompt_tokens_total": self.prompt_tokens_total,
            "completion_tokens_total": self.completion_tokens_total,
            "generated_tokens_total": self.generated_tokens_total,
            "avg_request_time_s": (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            ),
            "avg_request_tok_s": avg_request_tok_s,
            "avg_decode_tok_s": avg_decode_tok_s,
            "last_request_at": self.last_request_at,
        }


def analytics_db_path() -> str:
    configured_path = os.environ.get("MLX_PLATFORM_ANALYTICS_DB_PATH")
    if configured_path:
        return os.path.expanduser(configured_path)

    return os.path.expanduser(
        "~/Library/Application Support/Nativ/Analytics.sqlite3"
    )


def bucket_start_unix(timestamp: float, granularity: str) -> float:
    bucket_time = datetime.fromtimestamp(timestamp)
    if granularity == "hour":
        bucket_time = bucket_time.replace(minute=0, second=0, microsecond=0)
    else:
        bucket_time = bucket_time.replace(hour=0, minute=0, second=0, microsecond=0)
    return bucket_time.timestamp()


def seconds_to_milliseconds(value: float | None) -> int | None:
    if value is None:
        return None
    return max(0, int(round(float(value) * 1000)))


def gigabytes_to_bytes(value: float | None) -> int | None:
    if value is None:
        return None
    return max(0, int(round(float(value) * (1024**3))))


class AnalyticsStore:
    def __init__(self, path: str) -> None:
        self.path = path
        self.session_id = uuid.uuid4().hex
        self._lock = Lock()
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.execute("PRAGMA journal_mode = WAL")
        self._connection.execute("PRAGMA synchronous = NORMAL")
        self._connection.execute("PRAGMA busy_timeout = 3000")
        self._ensure_schema()
        self._start_session()
        atexit.register(self.close_session)

    def _ensure_schema(self) -> None:
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS request_events (
                request_id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                completed_at REAL NOT NULL,
                model_id TEXT NOT NULL,
                endpoint TEXT NOT NULL,
                status TEXT NOT NULL,
                streaming INTEGER NOT NULL,
                prompt_tokens INTEGER NOT NULL,
                completion_tokens INTEGER NOT NULL,
                generated_tokens INTEGER NOT NULL,
                request_elapsed_ms INTEGER,
                decode_elapsed_ms INTEGER,
                ttft_ms INTEGER,
                peak_memory_bytes INTEGER,
                prefill_tokens_per_second REAL,
                decode_tokens_per_second REAL,
                image_count INTEGER NOT NULL,
                audio_count INTEGER NOT NULL,
                structured_output INTEGER NOT NULL,
                thinking_enabled INTEGER NOT NULL,
                tool_calls INTEGER NOT NULL,
                finish_reason TEXT,
                backend TEXT,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS analytics_buckets (
                granularity TEXT NOT NULL,
                bucket_start REAL NOT NULL,
                model_id TEXT NOT NULL,
                requests_started INTEGER NOT NULL,
                requests_completed INTEGER NOT NULL,
                requests_failed INTEGER NOT NULL,
                streaming_requests INTEGER NOT NULL,
                prompt_tokens_total INTEGER NOT NULL,
                completion_tokens_total INTEGER NOT NULL,
                generated_tokens_total INTEGER NOT NULL,
                request_elapsed_ms_total INTEGER NOT NULL,
                decode_elapsed_ms_total INTEGER NOT NULL,
                peak_memory_bytes_max INTEGER,
                updated_at REAL NOT NULL,
                PRIMARY KEY (granularity, bucket_start, model_id)
            );

            CREATE TABLE IF NOT EXISTS server_sessions (
                session_id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                last_seen_at REAL NOT NULL,
                backend TEXT,
                loaded_model TEXT,
                loaded_adapter TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_request_events_completed_at
                ON request_events (completed_at);
            CREATE INDEX IF NOT EXISTS idx_request_events_model_completed_at
                ON request_events (model_id, completed_at);
            CREATE INDEX IF NOT EXISTS idx_request_events_status_completed_at
                ON request_events (status, completed_at);
            CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_bucket_start
                ON analytics_buckets (granularity, bucket_start);
            CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_model_bucket_start
                ON analytics_buckets (granularity, model_id, bucket_start);
            """
        )

    def _start_session(self) -> None:
        started_at = time.time()
        with self._lock:
            self._connection.execute(
                """
                INSERT OR REPLACE INTO server_sessions (
                    session_id,
                    started_at,
                    last_seen_at,
                    backend,
                    loaded_model,
                    loaded_adapter
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (self.session_id, started_at, started_at, BACKEND_NAME, None, None),
            )
            self._connection.commit()

    def heartbeat(self, runtime: dict[str, Any] | None = None) -> None:
        snapshot = runtime or {}
        current_time = time.time()
        with self._lock:
            self._connection.execute(
                """
                UPDATE server_sessions
                SET
                    last_seen_at = ?,
                    backend = COALESCE(?, backend),
                    loaded_model = COALESCE(?, loaded_model),
                    loaded_adapter = COALESCE(?, loaded_adapter)
                WHERE session_id = ?
                """,
                (
                    current_time,
                    BACKEND_NAME,
                    snapshot.get("loaded_model"),
                    snapshot.get("loaded_adapter"),
                    self.session_id,
                ),
            )
            self._connection.commit()

    def close_session(self) -> None:
        ended_at = time.time()
        with self._lock:
            self._connection.execute(
                """
                UPDATE server_sessions
                SET ended_at = ?, last_seen_at = ?
                WHERE session_id = ? AND ended_at IS NULL
                """,
                (ended_at, ended_at, self.session_id),
            )
            self._connection.commit()

    def record_event(self, event: dict[str, Any]) -> None:
        model_id = str(event.get("model_id") or "Unknown")
        completed_at = float(event["completed_at"])
        status = str(event.get("status") or "completed")
        is_completed = status == "completed"
        updated_at = time.time()

        record = (
            str(event["request_id"]),
            float(event["started_at"]),
            completed_at,
            model_id,
            str(event.get("endpoint") or "unknown"),
            status,
            1 if event.get("streaming") else 0,
            int(event.get("prompt_tokens") or 0),
            int(event.get("completion_tokens") or 0),
            int(event.get("generated_tokens") or 0),
            event.get("request_elapsed_ms"),
            event.get("decode_elapsed_ms"),
            event.get("ttft_ms"),
            event.get("peak_memory_bytes"),
            event.get("prefill_tokens_per_second"),
            event.get("decode_tokens_per_second"),
            int(event.get("image_count") or 0),
            int(event.get("audio_count") or 0),
            1 if event.get("structured_output") else 0,
            1 if event.get("thinking_enabled") else 0,
            1 if event.get("tool_calls") else 0,
            event.get("finish_reason"),
            event.get("backend"),
            updated_at,
        )

        with self._lock:
            cursor = self._connection.execute(
                """
                INSERT OR IGNORE INTO request_events (
                    request_id,
                    started_at,
                    completed_at,
                    model_id,
                    endpoint,
                    status,
                    streaming,
                    prompt_tokens,
                    completion_tokens,
                    generated_tokens,
                    request_elapsed_ms,
                    decode_elapsed_ms,
                    ttft_ms,
                    peak_memory_bytes,
                    prefill_tokens_per_second,
                    decode_tokens_per_second,
                    image_count,
                    audio_count,
                    structured_output,
                    thinking_enabled,
                    tool_calls,
                    finish_reason,
                    backend,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                record,
            )
            if cursor.rowcount == 0:
                self._connection.commit()
                return

            request_elapsed_ms_total = int(event.get("request_elapsed_ms") or 0) if is_completed else 0
            decode_elapsed_ms_total = int(event.get("decode_elapsed_ms") or 0) if is_completed else 0
            peak_memory_bytes = event.get("peak_memory_bytes") if is_completed else None

            for granularity in ("hour", "day"):
                self._connection.execute(
                    """
                    INSERT INTO analytics_buckets (
                        granularity,
                        bucket_start,
                        model_id,
                        requests_started,
                        requests_completed,
                        requests_failed,
                        streaming_requests,
                        prompt_tokens_total,
                        completion_tokens_total,
                        generated_tokens_total,
                        request_elapsed_ms_total,
                        decode_elapsed_ms_total,
                        peak_memory_bytes_max,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(granularity, bucket_start, model_id) DO UPDATE SET
                        requests_started = analytics_buckets.requests_started + excluded.requests_started,
                        requests_completed = analytics_buckets.requests_completed + excluded.requests_completed,
                        requests_failed = analytics_buckets.requests_failed + excluded.requests_failed,
                        streaming_requests = analytics_buckets.streaming_requests + excluded.streaming_requests,
                        prompt_tokens_total = analytics_buckets.prompt_tokens_total + excluded.prompt_tokens_total,
                        completion_tokens_total = analytics_buckets.completion_tokens_total + excluded.completion_tokens_total,
                        generated_tokens_total = analytics_buckets.generated_tokens_total + excluded.generated_tokens_total,
                        request_elapsed_ms_total = analytics_buckets.request_elapsed_ms_total + excluded.request_elapsed_ms_total,
                        decode_elapsed_ms_total = analytics_buckets.decode_elapsed_ms_total + excluded.decode_elapsed_ms_total,
                        peak_memory_bytes_max = CASE
                            WHEN analytics_buckets.peak_memory_bytes_max IS NULL THEN excluded.peak_memory_bytes_max
                            WHEN excluded.peak_memory_bytes_max IS NULL THEN analytics_buckets.peak_memory_bytes_max
                            ELSE MAX(analytics_buckets.peak_memory_bytes_max, excluded.peak_memory_bytes_max)
                        END,
                        updated_at = excluded.updated_at
                    """,
                    (
                        granularity,
                        bucket_start_unix(completed_at, granularity),
                        model_id,
                        1,
                        1 if is_completed else 0,
                        0 if is_completed else 1,
                        1 if event.get("streaming") else 0,
                        int(event.get("prompt_tokens") or 0) if is_completed else 0,
                        int(event.get("completion_tokens") or 0) if is_completed else 0,
                        int(event.get("generated_tokens") or 0) if is_completed else 0,
                        request_elapsed_ms_total,
                        decode_elapsed_ms_total,
                        peak_memory_bytes,
                        updated_at,
                    ),
                )

            self._connection.execute(
                """
                UPDATE server_sessions
                SET
                    last_seen_at = ?,
                    backend = COALESCE(?, backend)
                WHERE session_id = ?
                """,
                (updated_at, BACKEND_NAME, self.session_id),
            )
            self._connection.commit()


ANALYTICS_STORE = AnalyticsStore(analytics_db_path())


class MetricsTracker:
    def __init__(self) -> None:
        self._lock = Lock()
        self.started_at = time.time()
        self.requests_started = 0
        self.requests_completed = 0
        self.requests_failed = 0
        self.streaming_requests = 0
        self.in_flight = 0
        self.prompt_tokens_total = 0
        self.completion_tokens_total = 0
        self.generated_tokens_total = 0
        self.request_time_total_seconds = 0.0
        self.decode_time_total_seconds = 0.0
        self.last_request_at: float | None = None
        self.latest_request: dict[str, Any] | None = None
        self.models: dict[str, ModelAggregate] = {}

    def record_started(self, observation: RequestObservation) -> None:
        with self._lock:
            self.requests_started += 1
            self.in_flight += 1
            if observation.stream:
                self.streaming_requests += 1
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_started += 1
            if observation.stream:
                aggregate.streaming_requests += 1

    def record_failed(self, observation: RequestObservation) -> None:
        completed_at = time.time()
        event = {
            "request_id": observation.request_id,
            "started_at": observation.started_at_unix,
            "completed_at": completed_at,
            "model_id": observation.model or "Unknown",
            "endpoint": observation.endpoint,
            "status": "failed",
            "streaming": observation.stream,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "generated_tokens": 0,
            "request_elapsed_ms": seconds_to_milliseconds(
                max(0.0, time.perf_counter() - observation.start_time)
            ),
            "decode_elapsed_ms": None,
            "ttft_ms": seconds_to_milliseconds(
                max(0.0, observation.first_token_at - observation.start_time)
            )
            if observation.first_token_at is not None
            else None,
            "peak_memory_bytes": None,
            "prefill_tokens_per_second": None,
            "decode_tokens_per_second": None,
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_calls": False,
            "finish_reason": None,
            "backend": BACKEND_NAME,
        }

        with self._lock:
            self.requests_failed += 1
            self.in_flight = max(0, self.in_flight - 1)
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_failed += 1
            aggregate.last_request_at = completed_at

        try:
            ANALYTICS_STORE.record_event(event)
        except Exception as error:
            base.logger.warning("analytics persistence failed for failed request: %s", error)

    def record_completed(
        self,
        observation: RequestObservation,
        completion: dict[str, Any],
    ) -> None:
        completed_at = time.time()
        prompt_tokens = int(completion.get("prompt_tokens") or 0)
        completion_tokens = int(completion.get("completion_tokens") or 0)
        generated_tokens = int(completion.get("generated_tokens") or completion_tokens)
        elapsed = float(completion.get("request_elapsed_s") or 0.0)
        decode_tps = float(completion.get("decode_tok_s") or 0.0)
        reported_decode_time = float(completion.get("decode_elapsed_s") or 0.0)
        decode_time = reported_decode_time
        if decode_time <= 0 and generated_tokens > 0 and decode_tps > 0:
            decode_time = generated_tokens / decode_tps
        if decode_time <= 0 and generated_tokens > 0:
            decode_time = elapsed
        request_tok_s = completion.get("request_tok_s")
        if request_tok_s is None and elapsed > 0 and completion_tokens > 0:
            request_tok_s = completion_tokens / elapsed

        latest = {
            "timestamp_unix": completed_at,
            "endpoint": observation.endpoint,
            "model": completion.get("model") or observation.model,
            "stream": observation.stream,
            "backend": BACKEND_NAME,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_tokens": generated_tokens,
            "reasoning_tokens": 0,
            "total_tokens": prompt_tokens + generated_tokens,
            "prompt_eval_time_s": completion.get("prompt_eval_time_s"),
            "prefill_tok_s": completion.get("prefill_tok_s"),
            "ttft_s": completion.get("ttft_s"),
            "decode_elapsed_s": decode_time if decode_time > 0 else None,
            "request_elapsed_s": elapsed if elapsed > 0 else None,
            "request_tok_s": request_tok_s,
            "decode_tok_s": completion.get("decode_tok_s"),
            "peak_memory_gb": completion.get("peak_memory_gb"),
            "finish_reason": completion.get("finish_reason"),
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_parser": current_tool_parser(),
            "tool_calls": bool(completion.get("tool_calls")),
            "apc_enabled": base.apc_manager is not None,
        }

        event = {
            "request_id": observation.request_id,
            "started_at": observation.started_at_unix,
            "completed_at": completed_at,
            "model_id": latest["model"] or observation.model or "Unknown",
            "endpoint": observation.endpoint,
            "status": "completed",
            "streaming": observation.stream,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_tokens": generated_tokens,
            "request_elapsed_ms": seconds_to_milliseconds(
                elapsed if elapsed > 0 else None
            ),
            "decode_elapsed_ms": seconds_to_milliseconds(
                decode_time if decode_time > 0 else None
            ),
            "ttft_ms": seconds_to_milliseconds(completion.get("ttft_s")),
            "peak_memory_bytes": gigabytes_to_bytes(completion.get("peak_memory_gb")),
            "prefill_tokens_per_second": completion.get("prefill_tok_s"),
            "decode_tokens_per_second": completion.get("decode_tok_s"),
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_calls": bool(completion.get("tool_calls")),
            "finish_reason": completion.get("finish_reason"),
            "backend": BACKEND_NAME,
        }

        with self._lock:
            self.requests_completed += 1
            self.in_flight = max(0, self.in_flight - 1)
            self.prompt_tokens_total += prompt_tokens
            self.completion_tokens_total += completion_tokens
            self.generated_tokens_total += generated_tokens
            self.request_time_total_seconds += elapsed
            self.decode_time_total_seconds += max(0.0, decode_time)
            self.last_request_at = completed_at
            self.latest_request = latest

            model_key = latest["model"] or observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_completed += 1
            aggregate.prompt_tokens_total += prompt_tokens
            aggregate.completion_tokens_total += completion_tokens
            aggregate.generated_tokens_total += generated_tokens
            aggregate.request_time_total_seconds += elapsed
            aggregate.decode_time_total_seconds += max(0.0, decode_time)
            aggregate.last_request_at = completed_at

        try:
            ANALYTICS_STORE.record_event(event)
        except Exception as error:
            base.logger.warning("analytics persistence failed for completed request: %s", error)

    def snapshot(self) -> dict[str, Any]:
        runtime = current_runtime_snapshot()
        try:
            ANALYTICS_STORE.heartbeat(runtime)
        except Exception as error:
            base.logger.warning("analytics session heartbeat failed: %s", error)

        with self._lock:
            avg_request_time = (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            )
            avg_request_tok_s = (
                self.completion_tokens_total / self.request_time_total_seconds
                if self.request_time_total_seconds > 0
                else 0.0
            )
            avg_decode_tok_s = (
                self.generated_tokens_total / self.decode_time_total_seconds
                if self.decode_time_total_seconds > 0
                else 0.0
            )
            return {
                "latest": self.latest_request,
                "summary": {
                    "uptime_s": max(0.0, time.time() - self.started_at),
                    "requests_started": self.requests_started,
                    "requests_completed": self.requests_completed,
                    "requests_failed": self.requests_failed,
                    "streaming_requests": self.streaming_requests,
                    "in_flight": self.in_flight,
                    "prompt_tokens_total": self.prompt_tokens_total,
                    "completion_tokens_total": self.completion_tokens_total,
                    "generated_tokens_total": self.generated_tokens_total,
                    "avg_request_time_s": avg_request_time,
                    "avg_request_tok_s": avg_request_tok_s,
                    "avg_decode_tok_s": avg_decode_tok_s,
                    "last_request_at": self.last_request_at,
                },
                "server": runtime,
                "models": [
                    aggregate.to_dict()
                    for aggregate in sorted(
                        self.models.values(),
                        key=lambda item: (item.last_request_at or 0.0, item.model),
                        reverse=True,
                    )
                ],
            }


TRACKER = MetricsTracker()


def iter_message_media(messages: list[Any]) -> tuple[int, int]:
    image_count = 0
    audio_count = 0
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type in {"image_url", "input_image"}:
                image_count += 1
            elif item_type == "input_audio":
                audio_count += 1
    return image_count, audio_count


def resolve_thinking_enabled(payload: dict[str, Any]) -> bool:
    value = payload.get("enable_thinking")
    if isinstance(value, bool):
        return value
    return bool(base.get_server_enable_thinking())


def parse_request_observation(request: Request, payload: dict[str, Any]) -> RequestObservation:
    image_count = 0
    audio_count = 0
    if request.url.path.endswith("chat/completions"):
        image_count, audio_count = iter_message_media(payload.get("messages") or [])
    elif request.url.path.endswith("responses"):
        input_items = payload.get("input")
        if isinstance(input_items, list):
            image_count, audio_count = iter_message_media(input_items)

    return RequestObservation(
        request_id=uuid.uuid4().hex,
        endpoint=request.url.path.lstrip("/"),
        model=payload.get("model"),
        stream=bool(payload.get("stream")),
        image_count=image_count,
        audio_count=audio_count,
        structured_output=payload.get("response_format") is not None or payload.get("text") is not None,
        thinking_enabled=resolve_thinking_enabled(payload),
        started_at_unix=time.time(),
        start_time=time.perf_counter(),
    )


def current_tool_parser() -> str | None:
    processor = base.model_cache.get("processor") if isinstance(base.model_cache, dict) else None
    if processor is None:
        return None
    try:
        return base._infer_tool_parser_from_processor(processor)
    except Exception:
        return None


def current_runtime_snapshot() -> dict[str, Any]:
    config = base.model_cache.get("config") if isinstance(base.model_cache, dict) else None
    text_config = getattr(config, "text_config", None)
    loaded_context_size = getattr(text_config, "max_position_embeddings", None)

    queue_depth = 0
    requests_queue = getattr(getattr(base, "response_generator", None), "requests", None)
    if requests_queue is not None:
        try:
            queue_depth = requests_queue.qsize()
        except Exception:
            queue_depth = 0

    if base.apc_manager is not None:
        apc_snapshot = dict(base.apc_manager.stats_snapshot())
        apc_snapshot["enabled"] = True
    else:
        apc_snapshot = {"enabled": False}

    return {
        "loaded_model": base.model_cache.get("model_path") if isinstance(base.model_cache, dict) else None,
        "loaded_adapter": base.model_cache.get("adapter_path") if isinstance(base.model_cache, dict) else None,
        "loaded_context_size": loaded_context_size,
        "configured_context_limit": loaded_context_size,
        "effective_context_limit": loaded_context_size,
        "loaded_tool_parser": current_tool_parser(),
        "analytics_db_path": ANALYTICS_STORE.path,
        "continuous_batching_enabled": getattr(base, "response_generator", None) is not None,
        "request_queue_depth": queue_depth,
        "apc": apc_snapshot,
    }


class StreamAccumulator:
    def __init__(self, observation: RequestObservation, kind: str) -> None:
        self.observation = observation
        self.kind = kind
        self.model = observation.model
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.generated_tokens = 0
        self.prefill_tok_s: float | None = None
        self.decode_tok_s: float | None = None
        self.peak_memory_gb: float | None = None
        self.finish_reason: str | None = None
        self.tool_calls = False

    def feed(self, block: str) -> None:
        lines = [line for line in block.splitlines() if line]
        if not lines:
            return

        event_name = None
        data_parts: list[str] = []
        for line in lines:
            if line.startswith("event:"):
                event_name = line.partition(":")[2].strip()
            elif line.startswith("data:"):
                data_parts.append(line.partition(":")[2].lstrip())

        if not data_parts:
            return

        data_text = "\n".join(data_parts)
        if data_text == "[DONE]":
            return

        try:
            payload = json.loads(data_text)
        except json.JSONDecodeError:
            return

        if self.kind == "chat":
            self._consume_chat_chunk(payload)
        else:
            self._consume_responses_event(event_name, payload)

    def _consume_chat_chunk(self, payload: dict[str, Any]) -> None:
        self.model = payload.get("model") or self.model
        usage = payload.get("usage") or {}
        timings = payload.get("timings") or {}
        self.prompt_tokens = int(usage.get("prompt_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("completion_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("completion_tokens") or self.generated_tokens)
        if usage.get("prompt_tps") is not None:
            self.prefill_tok_s = float(usage["prompt_tps"])
        generation_tps = usage.get("generation_tps")
        if generation_tps is None:
            generation_tps = timings.get("predicted_per_second")
        if generation_tps is not None and float(generation_tps) > 0:
            self.decode_tok_s = float(generation_tps)
        peak_memory = timings.get("peak_memory")
        if peak_memory is None:
            peak_memory = usage.get("peak_memory")
        if peak_memory is not None:
            self.peak_memory_gb = float(peak_memory)

        choices = payload.get("choices") or []
        if not choices:
            return

        choice = choices[0] or {}
        if choice.get("finish_reason"):
            self.finish_reason = choice["finish_reason"]
        delta = choice.get("delta") or {}
        if delta.get("tool_calls"):
            self.tool_calls = True
        if self.observation.first_token_at is None:
            content = delta.get("content")
            reasoning = delta.get("reasoning")
            if (isinstance(content, str) and content) or (isinstance(reasoning, str) and reasoning):
                self.observation.first_token_at = time.perf_counter()

    def _consume_responses_event(self, event_name: str | None, payload: dict[str, Any]) -> None:
        if (
            event_name
            in {"response.output_text.delta", "response.reasoning_text.delta"}
            and payload.get("delta")
        ):
            if self.observation.first_token_at is None:
                self.observation.first_token_at = time.perf_counter()
            return

        if event_name == "response.output_text.done":
            generation_tps = (payload.get("timings") or {}).get("predicted_per_second")
            if generation_tps is not None and float(generation_tps) > 0:
                self.decode_tok_s = float(generation_tps)
            return

        if event_name != "response.completed":
            return

        response = payload.get("response") or {}
        self.model = response.get("model") or self.model
        usage = response.get("usage") or {}
        self.prompt_tokens = int(usage.get("input_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("output_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("output_tokens") or self.generated_tokens)

    def finalize(self) -> dict[str, Any]:
        elapsed = max(0.0, time.perf_counter() - self.observation.start_time)
        prompt_eval_time = None
        if self.prefill_tok_s and self.prefill_tok_s > 0 and self.prompt_tokens > 0:
            prompt_eval_time = self.prompt_tokens / self.prefill_tok_s

        return {
            "model": self.model,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "generated_tokens": self.generated_tokens or self.completion_tokens,
            "request_elapsed_s": elapsed,
            "request_tok_s": (
                self.completion_tokens / elapsed if elapsed > 0 and self.completion_tokens > 0 else None
            ),
            "decode_tok_s": self.decode_tok_s,
            "prompt_eval_time_s": prompt_eval_time,
            "prefill_tok_s": self.prefill_tok_s,
            "ttft_s": (
                max(0.0, self.observation.first_token_at - self.observation.start_time)
                if self.observation.first_token_at is not None
                else None
            ),
            "peak_memory_gb": self.peak_memory_gb,
            "finish_reason": self.finish_reason,
            "tool_calls": self.tool_calls or self.finish_reason == "tool_calls",
        }


def parse_chat_response(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    timings = payload.get("timings") or {}
    choices = payload.get("choices") or []
    choice = choices[0] if choices else {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("prompt_tokens") or 0)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    prompt_tps = usage.get("prompt_tps")
    generation_tps = usage.get("generation_tps")
    prompt_eval_time = (
        prompt_tokens / float(prompt_tps)
        if prompt_tps and float(prompt_tps) > 0 and prompt_tokens > 0
        else None
    )
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": int(usage.get("completion_tokens") or completion_tokens),
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": float(generation_tps) if generation_tps is not None else None,
        "prompt_eval_time_s": prompt_eval_time,
        "prefill_tok_s": float(prompt_tps) if prompt_tps is not None else None,
        "ttft_s": None,
        "peak_memory_gb": (
            float(timings["peak_memory"])
            if timings.get("peak_memory") is not None
            else float(usage["peak_memory"])
            if usage.get("peak_memory") is not None
            else None
        ),
        "finish_reason": choice.get("finish_reason"),
        "tool_calls": (
            choice.get("finish_reason") == "tool_calls"
            or bool((choice.get("message") or {}).get("tool_calls"))
        ),
    }


def parse_responses_body(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("input_tokens") or 0)
    completion_tokens = int(usage.get("output_tokens") or 0)
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": completion_tokens,
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": None,
        "prompt_eval_time_s": None,
        "prefill_tok_s": None,
        "ttft_s": None,
        "peak_memory_gb": None,
        "finish_reason": "stop",
        "tool_calls": False,
    }


def merge_base_metrics(
    completion: dict[str, Any],
    envelope: dict[str, Any] | None,
) -> dict[str, Any]:
    if not envelope:
        return completion

    merged = dict(completion)
    for key in (
        "model",
        "prompt_tokens",
        "completion_tokens",
        "generated_tokens",
        "request_elapsed_s",
        "request_tok_s",
        "decode_elapsed_s",
        "decode_tok_s",
        "prompt_eval_time_s",
        "prefill_tok_s",
        "ttft_s",
        "peak_memory_gb",
        "finish_reason",
        "tool_calls",
    ):
        value = envelope.get(key)
        if value is not None:
            merged[key] = value
    return merged


def install_base_metrics_capture() -> None:
    if getattr(base_openai, "_nativ_metrics_capture_installed", False):
        return

    original_build_metrics_envelope = getattr(
        base_openai,
        "_build_metrics_envelope",
        None,
    )
    if original_build_metrics_envelope is None:
        return

    def capturing_build_metrics_envelope(*args: Any, **kwargs: Any) -> dict[str, Any]:
        envelope = original_build_metrics_envelope(*args, **kwargs)
        capture = _BASE_METRICS_CAPTURE.get()
        if capture is not None:
            capture["envelope"] = dict(envelope)
        return envelope

    base_openai._build_metrics_envelope = capturing_build_metrics_envelope
    base_openai._nativ_metrics_capture_installed = True


async def materialize_response(response: Any) -> tuple[Any, bytes]:
    response_body = bytes(getattr(response, "body", b"") or b"")
    if response_body or not hasattr(response, "body_iterator"):
        return response, response_body

    chunks: list[bytes] = []
    async for chunk in response.body_iterator:
        if isinstance(chunk, bytes):
            chunks.append(chunk)
        elif isinstance(chunk, bytearray):
            chunks.append(bytes(chunk))
        else:
            chunks.append(str(chunk).encode("utf-8"))

    response_body = b"".join(chunks)
    rebuilt = Response(
        content=response_body,
        status_code=response.status_code,
        headers=dict(response.headers),
        media_type=getattr(response, "media_type", None),
        background=getattr(response, "background", None),
    )
    return rebuilt, response_body


def install_metrics_overlay() -> None:
    if getattr(base.app.state, "mlx_platform_metrics_installed", False):
        return
    base.app.state.mlx_platform_metrics_installed = True
    install_base_metrics_capture()

    @base.app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        if request.url.path not in TRACKED_PATHS:
            return await call_next(request)

        body = await request.body()
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except json.JSONDecodeError:
            payload = {}
        observation = parse_request_observation(request, payload)
        TRACKER.record_started(observation)
        metrics_capture: dict[str, Any] = {}
        capture_token = _BASE_METRICS_CAPTURE.set(metrics_capture)

        try:
            response = await call_next(request)
        except Exception:
            TRACKER.record_failed(observation)
            raise
        finally:
            _BASE_METRICS_CAPTURE.reset(capture_token)

        if response.status_code >= 400:
            TRACKER.record_failed(observation)
            return response

        content_type = response.headers.get("content-type", "")
        if "text/event-stream" in content_type and hasattr(response, "body_iterator"):
            accumulator = StreamAccumulator(
                observation,
                "chat" if request.url.path.endswith("chat/completions") else "responses",
            )
            original_iterator = response.body_iterator

            async def wrapped_iterator():
                buffer = ""
                try:
                    async for chunk in original_iterator:
                        text = (
                            chunk.decode("utf-8", errors="replace")
                            if isinstance(chunk, (bytes, bytearray))
                            else str(chunk)
                        )
                        buffer += text
                        while "\n\n" in buffer:
                            block, buffer = buffer.split("\n\n", 1)
                            try:
                                accumulator.feed(block)
                            except Exception as error:
                                base.logger.warning("metrics stream instrumentation failed: %s", error)
                        yield chunk
                    if buffer.strip():
                        try:
                            accumulator.feed(buffer)
                        except Exception as error:
                            base.logger.warning("metrics stream instrumentation failed: %s", error)
                    try:
                        completion = merge_base_metrics(
                            accumulator.finalize(),
                            metrics_capture.get("envelope"),
                        )
                        TRACKER.record_completed(observation, completion)
                    except Exception as error:
                        base.logger.warning("metrics completion instrumentation failed: %s", error)
                except Exception:
                    TRACKER.record_failed(observation)
                    raise

            response.body_iterator = wrapped_iterator()
            return response

        try:
            response, response_body = await materialize_response(response)
            if request.url.path.endswith("chat/completions"):
                completion = parse_chat_response(response_body, observation)
            else:
                completion = parse_responses_body(response_body, observation)
            completion = merge_base_metrics(
                completion,
                metrics_capture.get("envelope"),
            )
            TRACKER.record_completed(observation, completion)
        except Exception as error:
            base.logger.warning("metrics instrumentation failed for %s: %s", request.url.path, error)

        return response

    @base.app.get("/metrics")
    @base.app.get("/v1/metrics", include_in_schema=False)
    async def metrics_endpoint():
        return TRACKER.snapshot()

    @base.app.post("/models/load", include_in_schema=False)
    @base.app.post("/v1/models/load")
    def load_model_endpoint(request: Request, payload: dict[str, Any]):
        """Load or hot-swap the text model without restarting the server."""
        require_api_key = getattr(base, "_require_management_api_key", None)
        if require_api_key is not None:
            require_api_key(request)

        model = payload.get("model")
        if not isinstance(model, str) or not model.strip():
            raise HTTPException(status_code=400, detail="A non-empty model is required.")

        adapter = payload.get("adapter_path")
        if adapter is not None and not isinstance(adapter, str):
            raise HTTPException(status_code=400, detail="adapter_path must be a string or null.")

        try:
            base.get_cached_model(model.strip(), adapter)
        except HTTPException:
            raise
        except Exception as error:
            raise HTTPException(status_code=500, detail=f"Failed to load model: {error}") from error

        snapshot = current_runtime_snapshot()
        return {
            "status": "loaded",
            "model": snapshot.get("loaded_model"),
            "loaded_models": snapshot.get("loaded_models", {}),
        }


def main() -> None:
    install_metrics_overlay()
    install_metrics_access_log_filter()
    original_argparse = base_cli.argparse

    def nativ_argument_parser(*args: Any, **kwargs: Any):
        kwargs["description"] = "Nativ."
        return original_argparse.ArgumentParser(*args, **kwargs)

    base_cli.argparse = SimpleNamespace(ArgumentParser=nativ_argument_parser)
    try:
        base.main()
    finally:
        base_cli.argparse = original_argparse


install_metrics_overlay()


if __name__ == "__main__":
    main()
