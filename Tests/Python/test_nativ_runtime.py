from __future__ import annotations

import threading
import time
import unittest

from PythonDistribution.Overlay.nativ_runtime import ModelRuntimeGate


class ModelRuntimeGateTests(unittest.TestCase):
    def test_transition_closes_admission_and_waits_for_active_inference(self) -> None:
        gate = ModelRuntimeGate()
        self.assertTrue(gate.begin_inference())

        transition_entered = threading.Event()
        transition_finished = threading.Event()

        def transition() -> None:
            with gate.transition():
                transition_entered.set()
            transition_finished.set()

        thread = threading.Thread(target=transition)
        thread.start()
        try:
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if not gate.begin_inference():
                    break
                gate.end_inference()
                time.sleep(0.001)
            else:
                self.fail("The transition did not close inference admission.")

            self.assertFalse(transition_entered.is_set())
            gate.end_inference()
            self.assertTrue(transition_entered.wait(timeout=1))
            self.assertTrue(transition_finished.wait(timeout=1))
            self.assertTrue(gate.begin_inference())
            gate.end_inference()
        finally:
            thread.join(timeout=1)

    def test_inference_lease_underflow_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "underflow"):
            ModelRuntimeGate().end_inference()


if __name__ == "__main__":
    unittest.main()
