from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Overlay"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))

import build_mlx_vlm_server
from nativ_server_security import API_KEY_ENVIRONMENT_VARIABLE
from nativ_server_security import ServerAuthenticationMiddleware
from nativ_server_security import ServerSecurityConfigurationError
from nativ_server_security import remove_middleware
from nativ_server_security import requested_api_key
from nativ_server_security import requested_host
from nativ_server_security import validate_server_start


class ServerStartPolicyTests(unittest.TestCase):
    def test_loopback_requires_api_key(self) -> None:
        with self.assertRaisesRegex(
            ServerSecurityConfigurationError,
            "API key is required",
        ):
            validate_server_start(["--host", "127.0.0.1"], {})

    def test_non_loopback_is_rejected_with_api_key(self) -> None:
        with self.assertRaisesRegex(
            ServerSecurityConfigurationError,
            "not a loopback address",
        ):
            validate_server_start(
                ["--host", "0.0.0.0"],
                {API_KEY_ENVIRONMENT_VARIABLE: "nativ_test"},
            )

    def test_ipv4_and_ipv6_loopback_are_accepted(self) -> None:
        environment = {API_KEY_ENVIRONMENT_VARIABLE: "nativ_test"}
        validate_server_start(["--host=127.0.0.1"], environment)
        validate_server_start(["--host", "::1"], environment)

    def test_default_host_is_loopback(self) -> None:
        validate_server_start(
            [],
            {API_KEY_ENVIRONMENT_VARIABLE: "nativ_test"},
        )

    def test_help_does_not_require_runtime_security_configuration(self) -> None:
        validate_server_start(["--help"], {})

    def test_last_host_argument_wins(self) -> None:
        self.assertEqual(
            requested_host(["--host", "0.0.0.0", "--host=127.0.0.1"]),
            "127.0.0.1",
        )

    def test_command_line_api_key_is_accepted(self) -> None:
        validate_server_start(
            ["--host", "127.0.0.1", "--api-key", "nativ_test"],
            {},
        )
        self.assertEqual(
            requested_api_key(["--api-key=nativ_test"], {}),
            "nativ_test",
        )

    def test_blank_command_line_api_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            ServerSecurityConfigurationError,
            "API key is required",
        ):
            validate_server_start(["--api-key", " "], {})

    def test_missing_command_line_api_key_value_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            ServerSecurityConfigurationError,
            "--api-key requires a value",
        ):
            validate_server_start(["--api-key"], {})


class ServerAuthenticationMiddlewareTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.downstream_calls = 0
        self.messages: list[dict[str, object]] = []

        async def application(scope, receive, send) -> None:
            self.downstream_calls += 1
            if scope["type"] == "http":
                await send(
                    {
                        "type": "http.response.start",
                        "status": 204,
                        "headers": [],
                    }
                )
                await send({"type": "http.response.body", "body": b""})

        self.middleware = ServerAuthenticationMiddleware(
            application,
            api_key="nativ_test",
        )

    async def receive(self) -> dict[str, object]:
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(self, message: dict[str, object]) -> None:
        self.messages.append(message)

    async def test_http_request_without_credentials_is_rejected(self) -> None:
        await self.middleware(
            {"type": "http", "headers": []},
            self.receive,
            self.send,
        )
        self.assertEqual(self.downstream_calls, 0)
        self.assertEqual(self.messages[0]["status"], 401)
        self.assertIn(
            (b"www-authenticate", b"Bearer"),
            self.messages[0]["headers"],
        )

    async def test_http_request_with_credentials_is_allowed(self) -> None:
        await self.middleware(
            {
                "type": "http",
                "headers": [(b"authorization", b"Bearer nativ_test")],
            },
            self.receive,
            self.send,
        )
        self.assertEqual(self.downstream_calls, 1)
        self.assertEqual(self.messages[0]["status"], 204)

    async def test_duplicate_authorization_headers_are_rejected(self) -> None:
        await self.middleware(
            {
                "type": "http",
                "headers": [
                    (b"authorization", b"Bearer nativ_test"),
                    (b"authorization", b"Bearer nativ_test"),
                ],
            },
            self.receive,
            self.send,
        )
        self.assertEqual(self.downstream_calls, 0)
        self.assertEqual(self.messages[0]["status"], 401)

    async def test_websocket_without_credentials_is_closed(self) -> None:
        await self.middleware(
            {"type": "websocket", "headers": []},
            self.receive,
            self.send,
        )
        self.assertEqual(self.downstream_calls, 0)
        self.assertEqual(
            self.messages,
            [{"type": "websocket.close", "code": 1008}],
        )


class MiddlewareConfigurationTests(unittest.TestCase):
    def test_removes_every_matching_middleware_and_resets_stack(self) -> None:
        class RemovedMiddleware:
            pass

        class RetainedMiddleware:
            pass

        application = SimpleNamespace(
            user_middleware=[
                SimpleNamespace(cls=RemovedMiddleware),
                SimpleNamespace(cls=RetainedMiddleware),
                SimpleNamespace(cls=RemovedMiddleware),
            ],
            middleware_stack=object(),
        )
        remove_middleware(application, RemovedMiddleware)
        self.assertEqual(
            [item.cls for item in application.user_middleware],
            [RetainedMiddleware],
        )
        self.assertIsNone(application.middleware_stack)


class DistributionPackagingTests(unittest.TestCase):
    def test_installs_both_server_overlay_modules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            destination = output / "python/lib/python3.12/site-packages"
            destination.mkdir(parents=True)

            build_mlx_vlm_server.install_overlay(output)

            for source in (
                build_mlx_vlm_server.OVERLAY_SERVER,
                build_mlx_vlm_server.OVERLAY_SECURITY,
            ):
                installed = destination / source.name
                self.assertEqual(installed.read_bytes(), source.read_bytes())

    def test_security_overlay_changes_invalidate_distribution_cache(self) -> None:
        signature = build_mlx_vlm_server.build_signature(
            asset=build_mlx_vlm_server.Asset("python.tar.gz", "https://example.test"),
            python_version="3.12",
            pbs_release="test",
            target="aarch64-apple-darwin",
            requirements=None,
            mlx_vlm_source=None,
            mlx_audio_source=None,
            skip_install=False,
        )

        self.assertEqual(
            signature["overlay_security_sha256"],
            build_mlx_vlm_server.file_sha256(
                build_mlx_vlm_server.OVERLAY_SECURITY
            ),
        )


if __name__ == "__main__":
    unittest.main()
