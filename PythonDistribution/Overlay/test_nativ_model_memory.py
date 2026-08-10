"""Tests for the pure model-cache memory-budget decision logic.

Run with: python3 -m unittest test_nativ_model_memory -v
No external dependencies -- deliberately runnable with any Python 3.9+,
not just the bundled server's interpreter.
"""

from __future__ import annotations

import unittest

from nativ_model_memory import Decision, ResidentModel, SizeCache, TenantTable, decide

MODEL_A: tuple = ("org/model-a", None, "text_generation")
MODEL_B: tuple = ("org/model-b", None, "text_generation")
MODEL_C: tuple = ("org/model-c", None, "text_generation")


class DecideTests(unittest.TestCase):
    def test_loads_directly_when_it_already_fits(self) -> None:
        decision = decide(
            requested_size_bytes=1_000,
            resident=(),
            available_bytes=2_000,
        )
        self.assertEqual(decision, Decision(should_load=True))

    def test_prefers_resident_no_eviction_when_a_second_model_also_fits(self) -> None:
        resident = (ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=1, last_released_at=0.0),)
        decision = decide(
            requested_size_bytes=1_000,
            resident=resident,
            available_bytes=1_500,
        )
        self.assertEqual(decision, Decision(should_load=True))

    def test_evicts_least_recently_released_zero_tenant_model_when_needed(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=0, last_released_at=10.0),
            ResidentModel(cache_key=MODEL_B, size_bytes=1_000, active_tenants=0, last_released_at=5.0),
        )
        decision = decide(
            requested_size_bytes=1_000,
            resident=resident,
            available_bytes=0,
        )
        self.assertTrue(decision.should_load)
        self.assertEqual(decision.evict, (MODEL_B,))

    def test_evicts_only_as_many_as_actually_needed(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=0, last_released_at=1.0),
            ResidentModel(cache_key=MODEL_B, size_bytes=1_000, active_tenants=0, last_released_at=2.0),
        )
        decision = decide(
            requested_size_bytes=500,
            resident=resident,
            available_bytes=0,
        )
        self.assertTrue(decision.should_load)
        self.assertEqual(decision.evict, (MODEL_A,))

    def test_never_evicts_a_model_with_an_active_tenant(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=1, last_released_at=0.0),
        )
        decision = decide(
            requested_size_bytes=1_000,
            resident=resident,
            available_bytes=0,
        )
        self.assertFalse(decision.should_load)
        self.assertEqual(decision.evict, ())
        self.assertIsNotNone(decision.rejected_reason)

    def test_evicts_zero_tenant_models_but_skips_active_ones_to_make_room(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=1, last_released_at=0.0),
            ResidentModel(cache_key=MODEL_B, size_bytes=1_000, active_tenants=0, last_released_at=5.0),
        )
        decision = decide(
            requested_size_bytes=1_000,
            resident=resident,
            available_bytes=0,
        )
        self.assertTrue(decision.should_load)
        self.assertEqual(decision.evict, (MODEL_B,))

    def test_rejects_cleanly_when_still_short_after_evicting_everything_evictable(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=1, last_released_at=0.0),
            ResidentModel(cache_key=MODEL_B, size_bytes=500, active_tenants=0, last_released_at=1.0),
        )
        decision = decide(
            requested_size_bytes=10_000,
            resident=resident,
            available_bytes=0,
        )
        self.assertFalse(decision.should_load)
        self.assertEqual(decision.evict, ())
        self.assertIn("short by", decision.rejected_reason)

    def test_evicts_multiple_when_one_is_not_enough(self) -> None:
        resident = (
            ResidentModel(cache_key=MODEL_A, size_bytes=500, active_tenants=0, last_released_at=1.0),
            ResidentModel(cache_key=MODEL_B, size_bytes=500, active_tenants=0, last_released_at=2.0),
            ResidentModel(cache_key=MODEL_C, size_bytes=500, active_tenants=0, last_released_at=3.0),
        )
        decision = decide(
            requested_size_bytes=1_000,
            resident=resident,
            available_bytes=0,
        )
        self.assertTrue(decision.should_load)
        self.assertEqual(decision.evict, (MODEL_A, MODEL_B))

    def test_exact_fit_is_not_an_off_by_one_reject(self) -> None:
        decision = decide(
            requested_size_bytes=1_000,
            resident=(),
            available_bytes=1_000,
        )
        self.assertTrue(decision.should_load)


class DeliberateBreakTests(unittest.TestCase):
    """Proves the "never evict an active tenant" invariant is actually
    load-bearing in the real decide() implementation, not just asserted by
    a test that would pass regardless. A version of decide() that (wrongly)
    treats active_tenants as irrelevant would evict MODEL_A here -- confirm
    that variant actually fails this test, so the real implementation's
    pass isn't a coincidence."""

    def test_a_buggy_variant_ignoring_active_tenants_would_wrongly_evict(self) -> None:
        def buggy_decide(*, requested_size_bytes, resident, available_bytes):
            evictable = sorted(resident, key=lambda entry: entry.last_released_at)  # bug: no active_tenants filter
            freed = 0
            to_evict = []
            for entry in evictable:
                if requested_size_bytes <= available_bytes + freed:
                    break
                to_evict.append(entry.cache_key)
                freed += entry.size_bytes
            return Decision(should_load=requested_size_bytes <= available_bytes + freed, evict=tuple(to_evict))

        resident = (ResidentModel(cache_key=MODEL_A, size_bytes=1_000, active_tenants=1, last_released_at=0.0),)
        buggy_result = buggy_decide(requested_size_bytes=1_000, resident=resident, available_bytes=0)
        self.assertEqual(buggy_result.evict, (MODEL_A,), "sanity check: the buggy variant really does evict an in-use model")

        real_result = decide(requested_size_bytes=1_000, resident=resident, available_bytes=0)
        self.assertNotEqual(real_result.evict, (MODEL_A,))


class TenantTableTests(unittest.TestCase):
    def test_acquire_increments_and_release_decrements(self) -> None:
        table = TenantTable(time_fn=lambda: 42.0)
        table.acquire(MODEL_A)
        table.acquire(MODEL_A)
        self.assertEqual(table.active_count(MODEL_A), 2)
        table.release(MODEL_A)
        self.assertEqual(table.active_count(MODEL_A), 1)
        table.release(MODEL_A)
        self.assertEqual(table.active_count(MODEL_A), 0)

    def test_release_records_the_timestamp_only_when_it_reaches_zero(self) -> None:
        clock = iter([1.0, 2.0, 3.0])
        table = TenantTable(time_fn=lambda: next(clock))
        table.acquire(MODEL_A)
        table.acquire(MODEL_A)
        table.release(MODEL_A)  # still 1 active -- no timestamp recorded yet
        self.assertEqual(table.active_count(MODEL_A), 1)
        table.release(MODEL_A)  # now 0 -- this is the release that gets timestamped
        self.assertEqual(table.last_released_at(MODEL_A), 1.0)

    def test_release_on_an_unknown_or_already_zero_key_is_a_no_op(self) -> None:
        table = TenantTable(time_fn=lambda: 0.0)
        table.release(MODEL_A)
        self.assertEqual(table.active_count(MODEL_A), 0)

    def test_forget_clears_all_state_for_a_key(self) -> None:
        table = TenantTable(time_fn=lambda: 5.0)
        table.acquire(MODEL_A)
        table.release(MODEL_A)
        table.forget(MODEL_A)
        self.assertEqual(table.active_count(MODEL_A), 0)
        self.assertEqual(table.last_released_at(MODEL_A), 5.0)

    def test_any_active_is_false_when_nothing_is_in_flight(self) -> None:
        table = TenantTable(time_fn=lambda: 0.0)
        self.assertFalse(table.any_active())
        table.acquire(MODEL_A)
        table.release(MODEL_A)
        self.assertFalse(table.any_active())

    def test_any_active_is_true_for_any_key_not_just_a_queried_one(self) -> None:
        table = TenantTable(time_fn=lambda: 0.0)
        table.acquire(MODEL_B)
        self.assertFalse(table.active_count(MODEL_A) > 0)
        self.assertTrue(table.any_active())


class SizeCacheTests(unittest.TestCase):
    def test_estimate_falls_back_before_any_measurement(self) -> None:
        cache = SizeCache()
        self.assertEqual(cache.estimate(MODEL_A, fallback_bytes=999), 999)
        self.assertIsNone(cache.measured_size(MODEL_A))

    def test_estimate_prefers_the_real_measurement_once_recorded(self) -> None:
        cache = SizeCache()
        cache.record_measurement(MODEL_A, 12_345)
        self.assertEqual(cache.estimate(MODEL_A, fallback_bytes=999), 12_345)
        self.assertEqual(cache.measured_size(MODEL_A), 12_345)


if __name__ == "__main__":
    unittest.main()
