from __future__ import annotations

import ipaddress
import os
import secrets
from collections.abc import Mapping, Sequence
from typing import Any


API_KEY_ENVIRONMENT_VARIABLE = "MLX_VLM_SERVER_API_KEY"
LOOPBACK_SERVER_HOST = "127.0.0.1"
DEFAULT_SERVER_HOST = LOOPBACK_SERVER_HOST
HELP_ARGUMENTS = frozenset({"-h", "--help", "--version"})


class ServerSecurityConfigurationError(ValueError):
    pass


def normalized_api_key(value: str | None) -> str | None:
    if value is None:
        return None
    token = value.strip()
    return token if token else None


def requested_host(
    arguments: Sequence[str],
    default: str = DEFAULT_SERVER_HOST,
) -> str:
    host = default
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--host":
            if index + 1 >= len(arguments):
                raise ServerSecurityConfigurationError("--host requires a value")
            host = arguments[index + 1]
            index += 2
            continue
        if argument.startswith("--host="):
            host = argument.partition("=")[2]
        index += 1
    return host.strip()


def requested_api_key(
    arguments: Sequence[str],
    environment: Mapping[str, str],
) -> str | None:
    api_key = environment.get(API_KEY_ENVIRONMENT_VARIABLE)
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--api-key":
            if index + 1 >= len(arguments):
                raise ServerSecurityConfigurationError("--api-key requires a value")
            api_key = arguments[index + 1]
            index += 2
            continue
        if argument.startswith("--api-key="):
            api_key = argument.partition("=")[2]
        index += 1
    return normalized_api_key(api_key)


def is_loopback_host(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_server_start(
    arguments: Sequence[str],
    environment: Mapping[str, str] | None = None,
    default_host: str = DEFAULT_SERVER_HOST,
) -> None:
    if any(argument in HELP_ARGUMENTS for argument in arguments):
        return
    values = os.environ if environment is None else environment
    if requested_api_key(arguments, values) is None:
        raise ServerSecurityConfigurationError("A server API key is required")
    host = requested_host(arguments, default=default_host)
    if not is_loopback_host(host):
        raise ServerSecurityConfigurationError(
            f"Server host {host!r} is not a loopback address"
        )


def remove_middleware(application: Any, middleware_type: type[Any]) -> None:
    middleware = application.user_middleware
    retained = [item for item in middleware if item.cls is not middleware_type]
    if len(retained) == len(middleware):
        return
    application.user_middleware = retained
    application.middleware_stack = None


class ServerAuthenticationMiddleware:
    def __init__(self, application: Any, api_key: str | None = None) -> None:
        token = normalized_api_key(
            os.environ.get(API_KEY_ENVIRONMENT_VARIABLE) if api_key is None else api_key
        )
        if token is None:
            raise ServerSecurityConfigurationError("A server API key is required")
        self.application = application
        self.expected_authorization = f"Bearer {token}".encode("utf-8")

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] not in {"http", "websocket"}:
            await self.application(scope, receive, send)
            return
        authorization = [
            value
            for name, value in scope.get("headers", [])
            if name.lower() == b"authorization"
        ]
        if len(authorization) == 1 and secrets.compare_digest(
            authorization[0], self.expected_authorization
        ):
            await self.application(scope, receive, send)
            return
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
            return
        body = b'{"detail":"Not authenticated"}'
        await send(
            {
                "type": "http.response.start",
                "status": 401,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                    (b"www-authenticate", b"Bearer"),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})
