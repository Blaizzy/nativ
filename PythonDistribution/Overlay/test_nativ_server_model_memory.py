"""Integration-level tests for nativ_server.py's model-memory wiring itself
(not just the pure decision logic in nativ_model_memory.py, already covered
by test_nativ_model_memory.py).

Unlike that file, this one needs the bundled server's own interpreter (mlx,
fastapi, mlx_vlm installed) since nativ_server.py imports them at module
level. Run with the bundled python3, e.g.:

  "$NATIV_APP/.../mlx-vlm-server/python/bin/python3" -m unittest \
      test_nativ_server_model_memory -v

Real GPU model loading is mocked out entirely (via monkeypatching
_ORIGINAL_GET_CACHED_MODEL and the mx.* memory-query calls) -- these tests
exercise the actual reject/evict/coexist wiring and tenant lifecycle, not
real model weights.
"""

from __future__ import annotations

import unittest
from unittest import mock

import nativ_server


class NativGetCachedModelPoolHitTests(unittest.TestCase):
    def setUp(self) -> None:
        nativ_server._TEXT_GEN_POOL.clear()
        nativ_server._TEXT_GEN_LAST_USED.clear()
        nativ_server._TENANTS = nativ_server.TenantTable()
        nativ_server._SIZES = nativ_server.SizeCache()

    def test_pool_hit_returns_the_resident_entry_without_calling_the_loader(self) -> None:
        cache_key = ("org/model-a", None, "text_generation")
        fake_entry = {
            "model": "fake-model",
            "processor": "fake-processor",
            "config": "fake-config",
            "response_generator": "fake-generator",
            "apc_manager": "fake-apc",
        }
        nativ_server._TEXT_GEN_POOL[cache_key] = fake_entry
        nativ_server._TEXT_GEN_LAST_USED[cache_key] = 1.0

        original_loader = mock.Mock(side_effect=AssertionError("must not be called on a pool hit"))
        with mock.patch.object(nativ_server, "_ORIGINAL_GET_CACHED_MODEL", original_loader):
            model, processor, config = nativ_server.nativ_get_cached_model("org/model-a", None)

        self.assertEqual((model, processor, config), ("fake-model", "fake-processor", "fake-config"))
        original_loader.assert_not_called()
        self.assertEqual(nativ_server._TENANTS.active_count(cache_key), 1)

    def test_pool_hit_sets_the_contextvar_backed_response_generator(self) -> None:
        cache_key = ("org/model-a", None, "text_generation")
        nativ_server._TEXT_GEN_POOL[cache_key] = {
            "model": "m",
            "processor": "p",
            "config": "c",
            "response_generator": "the-real-generator",
            "apc_manager": "the-real-apc",
        }
        nativ_server._TEXT_GEN_LAST_USED[cache_key] = 1.0

        with mock.patch.object(nativ_server, "_ORIGINAL_GET_CACHED_MODEL", mock.Mock()):
            nativ_server.nativ_get_cached_model("org/model-a", None)

        self.assertEqual(nativ_server.base.runtime.response_generator, "the-real-generator")
        self.assertEqual(nativ_server.base.runtime.apc_manager, "the-real-apc")


class NativGetCachedModelRejectTests(unittest.TestCase):
    def setUp(self) -> None:
        nativ_server._TEXT_GEN_POOL.clear()
        nativ_server._TEXT_GEN_LAST_USED.clear()
        nativ_server._TENANTS = nativ_server.TenantTable()
        nativ_server._SIZES = nativ_server.SizeCache()

    def test_rejects_cleanly_without_ever_calling_the_loader_when_nothing_fits(self) -> None:
        busy_key = ("org/busy-model", None, "text_generation")
        nativ_server._TEXT_GEN_POOL[busy_key] = {
            "model": "busy",
            "processor": None,
            "config": None,
            "response_generator": mock.Mock(),
            "apc_manager": None,
        }
        nativ_server._TENANTS.acquire(busy_key)
        nativ_server._SIZES.record_measurement(busy_key, 1_000)
        nativ_server._TEXT_GEN_LAST_USED[busy_key] = 1.0

        original_loader = mock.Mock(side_effect=AssertionError("must not attempt a load that was rejected"))
        with (
            mock.patch.object(nativ_server, "_ORIGINAL_GET_CACHED_MODEL", original_loader),
            mock.patch.object(nativ_server, "_text_generation_memory_budget_bytes", return_value=0),
            mock.patch.object(nativ_server, "_estimate_model_size_on_disk", return_value=1_000),
        ):
            with self.assertRaises(nativ_server.HTTPException) as ctx:
                nativ_server.nativ_get_cached_model("org/new-model", None)

        original_loader.assert_not_called()
        self.assertEqual(ctx.exception.status_code, 507)
        self.assertEqual(ctx.exception.detail["error"], nativ_server.INSUFFICIENT_MEMORY_ERROR_KIND)
        self.assertEqual(ctx.exception.detail["model"], "org/new-model")
        self.assertIn(busy_key, nativ_server._TEXT_GEN_POOL)


class ReleaseAfterPreloadTests(unittest.TestCase):
    def setUp(self) -> None:
        nativ_server._TENANTS = nativ_server.TenantTable()

    def test_releases_the_deterministic_cache_key_for_a_text_generation_model(self) -> None:
        cache_key = ("org/model-a", "adapter-x", "text_generation")
        nativ_server._TENANTS.acquire(cache_key)
        self.assertEqual(nativ_server._TENANTS.active_count(cache_key), 1)

        with mock.patch.object(nativ_server.base_app, "is_image_generation_model", return_value=False):
            nativ_server.release_text_generation_tenant_after_preload("org/model-a", "adapter-x")

        self.assertEqual(nativ_server._TENANTS.active_count(cache_key), 0)

    def test_is_a_no_op_for_an_image_generation_model(self) -> None:
        with mock.patch.object(nativ_server.base_app, "is_image_generation_model", return_value=True):
            nativ_server.release_text_generation_tenant_after_preload("org/image-model", None)


class InstallIsIdempotentTests(unittest.TestCase):
    def test_installing_twice_does_not_double_wrap(self) -> None:
        first = nativ_server.base_app.get_cached_model
        nativ_server.install_model_memory_management()
        second = nativ_server.base_app.get_cached_model
        self.assertIs(first, second)


if __name__ == "__main__":
    unittest.main()
