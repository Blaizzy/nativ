"""Regression coverage for clearing startup fallbacks through live settings."""
import ast
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class RuntimeSettingsTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_server.py"
        node = next(node for node in ast.parse(source.read_text()).body
                    if isinstance(node, ast.FunctionDef) and node.name == "install_runtime_settings_overlay")

        class RuntimeConfig:
            def __init__(self):
                self.values = {"kv_bits": 8, "draft_model": "startup-draft", "max_kv_size": 4096}

            def apply_changes(self, values, op="merge"):
                if op == "replace":
                    self.values = {"kv_bits": 8, "draft_model": "startup-draft", "max_kv_size": 4096}
                accepted = {name: value for name, value in values.items() if value != "invalid"}
                rejected = [{"name": name} for name, value in values.items() if value == "invalid"]
                self.values.update(accepted)
                return accepted, rejected

            def current(self):
                return dict(self.values)

        self.config_type = RuntimeConfig
        self.config = RuntimeConfig()
        namespace = {"os": os}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)
        with patch.dict(sys.modules, {"mlx_vlm.server.runtime_config": SimpleNamespace(RuntimeConfig=RuntimeConfig)}):
            namespace["install_runtime_settings_overlay"]()
            self.wrapped = RuntimeConfig.apply_changes
            namespace["install_runtime_settings_overlay"]()
            self.assertIs(RuntimeConfig.apply_changes, self.wrapped)
        environment = patch.dict(os.environ, {
            "KV_BITS": "8", "MLX_VLM_DRAFT_MODEL": "startup-draft", "MAX_KV_SIZE": "4096",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def test_clear_removes_startup_fallbacks(self):
        self.config.apply_changes({"kv_bits": None, "draft_model": None, "max_kv_size": 0})
        self.assertNotIn("KV_BITS", os.environ)
        self.assertNotIn("MLX_VLM_DRAFT_MODEL", os.environ)
        self.assertEqual(os.environ["MAX_KV_SIZE"], "0")

    def test_rejected_values_do_not_change_fallbacks(self):
        applied, rejected = self.config.apply_changes({"kv_bits": "invalid", "apc_enabled": False})
        self.assertEqual(os.environ["KV_BITS"], "8")
        self.assertEqual(os.environ["APC_ENABLED"], "0")
        self.assertEqual(applied, {"apc_enabled": False})
        self.assertEqual(rejected, [{"name": "kv_bits"}])

    def test_replace_restores_startup_fallbacks_and_new_instances_are_wrapped(self):
        config = self.config_type()
        config.apply_changes({"kv_bits": None, "draft_model": None, "max_kv_size": 0})
        config.apply_changes({}, op="replace")
        self.assertEqual(os.environ["KV_BITS"], "8")
        self.assertEqual(os.environ["MLX_VLM_DRAFT_MODEL"], "startup-draft")
        self.assertEqual(os.environ["MAX_KV_SIZE"], "4096")

    def test_older_engine_draft_names_clear_the_same_fallbacks(self):
        self.config.apply_changes({"spec_draft_model": None, "spec_draft_kind": "mtp"})
        self.assertNotIn("MLX_VLM_DRAFT_MODEL", os.environ)
        self.assertEqual(os.environ["MLX_VLM_DRAFT_KIND"], "mtp")


if __name__ == "__main__":
    unittest.main()
