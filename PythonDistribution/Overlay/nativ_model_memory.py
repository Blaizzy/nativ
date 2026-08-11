"""Memory-budget decision logic for the embedded server's model cache.

Deliberately dependency-free (no mlx/fastapi imports) so it's unit-testable
without a GPU or a running server; nativ_server.py owns the real glue.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

CacheKey = tuple[str, Optional[str], str]  # (model_path, adapter_path, effective_model_kind)


@dataclass(frozen=True)
class ResidentModel:
    """A currently-loaded model the decision function knows about."""

    cache_key: CacheKey
    size_bytes: int
    active_tenants: int
    last_released_at: float  # monotonic; only meaningful when active_tenants == 0


@dataclass(frozen=True)
class Decision:
    """The outcome of a load request against the current memory budget."""

    should_load: bool
    evict: tuple[CacheKey, ...] = ()
    rejected_reason: Optional[str] = None


def decide(
    *,
    requested_size_bytes: int,
    resident: tuple[ResidentModel, ...],
    available_bytes: int,
) -> Decision:
    """Decide whether a model load can proceed, and what to evict first.

    `resident` must not include the model actually being requested --
    callers resolve an exact-match cache hit before reaching this function.
    """
    if requested_size_bytes <= available_bytes:
        # Prefer keeping resident: there's room, so nothing evicts just
        # because a different model was requested.
        return Decision(should_load=True)

    # Only ever evict zero-tenant entries, least-recently-released first,
    # and only as many as actually needed.
    evictable = sorted(
        (entry for entry in resident if entry.active_tenants == 0),
        key=lambda entry: entry.last_released_at,
    )

    freed = 0
    to_evict: list[CacheKey] = []
    for entry in evictable:
        if requested_size_bytes <= available_bytes + freed:
            break
        to_evict.append(entry.cache_key)
        freed += entry.size_bytes

    if requested_size_bytes <= available_bytes + freed:
        return Decision(should_load=True, evict=tuple(to_evict))

    shortfall = requested_size_bytes - (available_bytes + freed)
    return Decision(
        should_load=False,
        rejected_reason=(
            f"model requires {requested_size_bytes} bytes; only "
            f"{available_bytes + freed} bytes would be free even after "
            f"evicting every unused resident model (short by {shortfall} bytes)"
        ),
    )


class TenantTable:
    """Tracks how many in-flight requests are actively using each resident
    model. A model with active_count > 0 must never be evicted."""

    def __init__(self, *, time_fn=time.monotonic) -> None:
        self._time_fn = time_fn
        self._active_counts: dict[CacheKey, int] = {}
        self._last_released_at: dict[CacheKey, float] = {}

    def acquire(self, key: CacheKey) -> None:
        self._active_counts[key] = self._active_counts.get(key, 0) + 1

    def release(self, key: CacheKey) -> None:
        count = self._active_counts.get(key, 0)
        if count <= 0:
            return
        count -= 1
        self._active_counts[key] = count
        if count == 0:
            self._last_released_at[key] = self._time_fn()

    def active_count(self, key: CacheKey) -> int:
        return self._active_counts.get(key, 0)

    def any_active(self) -> bool:
        """Whether *any* resident model, not just a specific key, currently
        has an in-flight generation against it. For callers whose action
        would affect every resident model at once (e.g. a full server
        restart) rather than a single cache_key's eviction."""
        return any(count > 0 for count in self._active_counts.values())

    def last_released_at(self, key: CacheKey) -> float:
        # Never-released entries sort as "just released", not "oldest".
        return self._last_released_at.get(key, self._time_fn())

    def forget(self, key: CacheKey) -> None:
        self._active_counts.pop(key, None)
        self._last_released_at.pop(key, None)


class SizeCache:
    """Caches each model's real measured resident size, refined after its
    first successful load; falls back to a caller-supplied pessimistic
    estimate (e.g. on-disk size) before that."""

    def __init__(self) -> None:
        self._measured: dict[CacheKey, int] = {}

    def measured_size(self, key: CacheKey) -> Optional[int]:
        return self._measured.get(key)

    def record_measurement(self, key: CacheKey, size_bytes: int) -> None:
        self._measured[key] = size_bytes

    def estimate(self, key: CacheKey, *, fallback_bytes: int) -> int:
        return self._measured.get(key, fallback_bytes)
