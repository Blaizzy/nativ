from __future__ import annotations

from contextlib import contextmanager
from threading import Condition
from typing import Iterator


class ModelRuntimeGate:
    """Coordinate inference leases with destructive model-runtime transitions."""

    def __init__(self) -> None:
        self._condition = Condition()
        self._active_inference_requests = 0
        self._transition_in_progress = False

    def begin_inference(self) -> bool:
        """Acquire an inference lease, or return False while a transition owns admission."""

        with self._condition:
            if self._transition_in_progress:
                return False
            self._active_inference_requests += 1
            return True

    def end_inference(self) -> None:
        with self._condition:
            if self._active_inference_requests <= 0:
                raise RuntimeError("Model runtime inference lease underflow.")
            self._active_inference_requests -= 1
            if self._active_inference_requests == 0:
                self._condition.notify_all()

    @contextmanager
    def transition(self) -> Iterator[None]:
        """Close admission, drain active leases, and exclusively mutate the runtime."""

        with self._condition:
            if self._transition_in_progress:
                raise RuntimeError("A model runtime transition is already in progress.")
            self._transition_in_progress = True
            while self._active_inference_requests > 0:
                self._condition.wait()
        try:
            yield
        finally:
            with self._condition:
                self._transition_in_progress = False
                self._condition.notify_all()
