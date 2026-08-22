import argparse
import atexit
import importlib.util
import logging
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


OVERLAY_PATH = Path(__file__).parents[1] / "Overlay" / "nativ_server.py"


class StubAPCManager:
    def __init__(self, contents=None, clear_error=None):
        self.contents = list(contents or [])
        self.clear_error = clear_error
        self.clear_count = 0

    def clear(self):
        self.clear_count += 1
        if self.clear_error is not None:
            raise self.clear_error
        self.contents.clear()

    def stats_snapshot(self):
        return {"entries": len(self.contents)}


class StubModelCacheRegistry:
    def __init__(self, text_cache=None):
        self.caches = {}
        if text_cache is not None:
            self.caches["text_generation"] = text_cache

    def for_kind(self, cache_group):
        return self.caches.get(cache_group, {})

    def items(self):
        return self.caches.items()

    def pop(self, cache_group):
        return self.caches.pop(cache_group, None)

    def set(self, cache_group, cache):
        self.caches[cache_group] = cache


class StubApp:
    def __init__(self):
        self.state = types.SimpleNamespace()

    @staticmethod
    def _decorator(*args, **kwargs):
        del args, kwargs

        def register(function):
            return function

        return register

    middleware = _decorator
    get = _decorator
    post = _decorator


class NativServerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()

    def tearDown(self):
        module = sys.modules.pop("nativ_server", None)
        if module is not None:
            atexit.unregister(module.ANALYTICS_STORE.close_session)
            module.ANALYTICS_STORE.close_session()
            module.ANALYTICS_STORE._connection.close()
        self.temp_directory.cleanup()

    def load_overlay(self, apc_manager):
        app = StubApp()
        lifecycle = types.SimpleNamespace(
            resident=True,
            release_calls=[],
            initialization_cache_contents=[],
        )
        text_cache = {
            "model_path": "old-model",
            "adapter_path": None,
            "model_kind": "text_generation",
            "response_generator": object(),
            "apc_manager": apc_manager,
        }
        registry = StubModelCacheRegistry(text_cache)
        runtime = types.SimpleNamespace(
            model_cache=registry,
            response_generator=text_cache["response_generator"],
            apc_manager=apc_manager,
        )

        mlx = types.ModuleType("mlx")
        mlx.__path__ = []
        mx = types.ModuleType("mlx.core")

        class Array:
            pass

        mx.array = Array
        mx.eval = lambda *trees: None
        mlx.core = mx
        mlx_utils = types.ModuleType("mlx.utils")
        mlx_utils.tree_flatten = lambda tree: []

        fastapi = types.ModuleType("fastapi")

        class HTTPException(Exception):
            def __init__(self, status_code, detail):
                super().__init__(detail)
                self.status_code = status_code
                self.detail = detail

        class Request:
            pass

        class Response:
            def __init__(self, content=b"", **kwargs):
                self.body = content
                self.status_code = kwargs.get("status_code", 200)
                self.headers = kwargs.get("headers", {})
                self.media_type = kwargs.get("media_type")
                self.background = kwargs.get("background")

        fastapi.HTTPException = HTTPException
        fastapi.Request = Request
        fastapi_responses = types.ModuleType("fastapi.responses")
        fastapi_responses.Response = Response

        mlx_vlm = types.ModuleType("mlx_vlm")
        mlx_vlm.__path__ = []
        server = types.ModuleType("mlx_vlm.server")
        server.__path__ = []
        server.__version__ = "test"
        server.app = app
        server.logger = logging.getLogger("test.nativ_server")
        server.model_cache = registry
        server.response_generator = runtime.response_generator
        server.apc_manager = apc_manager
        server.get_server_enable_thinking = lambda: False
        server._infer_tool_parser_from_processor = lambda processor: None
        server.main = lambda: None

        server_app = types.ModuleType("mlx_vlm.server.app")
        server_app.runtime = runtime
        server_app.app = app
        server_app._model_cache_registry = lambda: registry

        def unload_cache_group(cache_group):
            cache = registry.for_kind(cache_group)
            if not cache:
                return False
            lifecycle.release_calls.append(cache_group)
            registry.pop(cache_group)
            runtime.response_generator = None
            runtime.apc_manager = None
            lifecycle.resident = False
            return True

        server_app._unload_model_cache_group = unload_cache_group
        server._unload_model_cache_group = unload_cache_group

        def unload_model_sync():
            unloaded = False
            for cache_group, _ in list(registry.items()):
                unloaded = server_app._unload_model_cache_group(cache_group) or unloaded
            return unloaded

        server_app.unload_model_sync = unload_model_sync
        server.unload_model_sync = unload_model_sync

        def get_cached_model(model_path, adapter_path=None):
            cached = registry.for_kind("text_generation")
            if cached and cached.get("model_path") != model_path:
                server_app._unload_model_cache_group("text_generation")
            cached = registry.for_kind("text_generation")
            if not cached:
                lifecycle.initialization_cache_contents.append(
                    None if apc_manager is None else list(apc_manager.contents)
                )
                new_cache = {
                    "model_path": model_path,
                    "adapter_path": adapter_path,
                    "model_kind": "text_generation",
                    "response_generator": object(),
                    "apc_manager": apc_manager,
                }
                registry.set("text_generation", new_cache)
                runtime.response_generator = new_cache["response_generator"]
                runtime.apc_manager = apc_manager
                lifecycle.resident = True
            return object(), object(), object()

        server_app.get_cached_model = get_cached_model
        server.get_cached_model = get_cached_model

        server_cli = types.ModuleType("mlx_vlm.server.cli")
        server_cli.argparse = argparse
        server_generation = types.ModuleType("mlx_vlm.server.generation")

        class ResponseGenerator:
            def _initialize_model(self):
                return None

        server_generation.ResponseGenerator = ResponseGenerator
        server_generation.load = lambda *args, **kwargs: None
        server_openai = types.ModuleType("mlx_vlm.server.openai")

        modules = {
            "mlx": mlx,
            "mlx.core": mx,
            "mlx.utils": mlx_utils,
            "fastapi": fastapi,
            "fastapi.responses": fastapi_responses,
            "mlx_vlm": mlx_vlm,
            "mlx_vlm.server": server,
            "mlx_vlm.server.app": server_app,
            "mlx_vlm.server.cli": server_cli,
            "mlx_vlm.server.generation": server_generation,
            "mlx_vlm.server.openai": server_openai,
        }
        spec = importlib.util.spec_from_file_location("nativ_server", OVERLAY_PATH)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules), patch.dict(
            os.environ,
            {
                "MLX_PLATFORM_ANALYTICS_DB_PATH": str(
                    Path(self.temp_directory.name) / "Analytics.sqlite3"
                )
            },
        ):
            sys.modules["nativ_server"] = module
            spec.loader.exec_module(module)
        sys.modules["nativ_server"] = module
        return module, server, server_app, lifecycle

    def test_automatic_eviction_clears_apc_before_reload(self):
        manager = StubAPCManager(["released-model-prefix"])
        _, server, _, lifecycle = self.load_overlay(manager)

        server.get_cached_model("new-model")

        self.assertEqual(manager.contents, [])
        self.assertEqual(lifecycle.initialization_cache_contents, [[]])
        self.assertEqual(lifecycle.release_calls, ["text_generation"])
        self.assertTrue(lifecycle.resident)

    def test_eviction_is_a_noop_for_disabled_apc(self):
        _, server, _, lifecycle = self.load_overlay(None)

        server.get_cached_model("new-model")

        self.assertEqual(lifecycle.initialization_cache_contents, [None])
        self.assertEqual(lifecycle.release_calls, ["text_generation"])
        self.assertTrue(lifecycle.resident)

    def test_cache_is_retained_when_no_eviction_occurs(self):
        manager = StubAPCManager(["reusable-prefix"])
        _, server, _, lifecycle = self.load_overlay(manager)

        server.get_cached_model("old-model")

        self.assertEqual(manager.contents, ["reusable-prefix"])
        self.assertEqual(manager.clear_count, 0)
        self.assertEqual(lifecycle.release_calls, [])

    def test_explicit_unload_cleanup_is_repeatable_and_reloadable(self):
        manager = StubAPCManager(["released-model-prefix"])
        _, server, server_app, lifecycle = self.load_overlay(manager)

        self.assertTrue(server_app.unload_model_sync())
        self.assertFalse(server_app.unload_model_sync())
        server.get_cached_model("old-model")

        self.assertEqual(manager.contents, [])
        self.assertGreaterEqual(manager.clear_count, 1)
        self.assertEqual(lifecycle.initialization_cache_contents, [[]])
        self.assertTrue(lifecycle.resident)

    def test_apc_cleanup_failure_prevents_partial_release(self):
        manager = StubAPCManager(
            ["released-model-prefix"],
            clear_error=RuntimeError("APC cleanup failed"),
        )
        _, _, server_app, lifecycle = self.load_overlay(manager)

        with self.assertRaisesRegex(RuntimeError, "APC cleanup failed"):
            server_app._unload_model_cache_group("text_generation")

        self.assertEqual(manager.contents, ["released-model-prefix"])
        self.assertEqual(lifecycle.release_calls, [])
        self.assertTrue(lifecycle.resident)


if __name__ == "__main__":
    unittest.main()
