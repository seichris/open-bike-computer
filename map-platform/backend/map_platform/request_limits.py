from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from typing import Any


class RequestBodyLimitMiddleware:
    """Bound request bodies before framework JSON parsing allocates them.

    `body_limits` keys are `(method, path)`. A path ending in `/*` matches
    exactly one further path segment, for routes such as `/items/{id}`.
    """

    def __init__(self, app: Callable[..., Awaitable[None]], max_body_bytes: int, body_limits: dict[tuple[str, str], int] | None = None):
        if max_body_bytes < 1:
            raise ValueError("maximum request body size must be positive")
        self.app = app
        self.max_body_bytes = max_body_bytes
        self.body_limits = body_limits or {}

    async def __call__(self, scope: dict[str, Any], receive, send) -> None:
        if scope.get("type") != "http" or scope.get("method") in {"GET", "HEAD"}:
            await self.app(scope, receive, send)
            return

        limit = self._limit(scope.get("method"), scope.get("path") or "")
        content_length = self._content_length(scope)
        if content_length is not None and content_length > limit:
            await self._reject(send)
            return

        messages: list[dict[str, Any]] = []
        received = 0
        while True:
            message = await receive()
            messages.append(message)
            if message.get("type") != "http.request":
                break
            received += len(message.get("body", b""))
            if received > limit:
                await self._reject(send)
                return
            if not message.get("more_body", False):
                break

        async def replay_receive() -> dict[str, Any]:
            if messages:
                return messages.pop(0)
            return await receive()

        await self.app(scope, replay_receive, send)

    def _limit(self, method: str | None, path: str) -> int:
        exact = self.body_limits.get((method, path))
        if exact is not None:
            return exact
        for (limited_method, pattern), limit in self.body_limits.items():
            if limited_method != method or not pattern.endswith("/*"):
                continue
            prefix = pattern[:-1]
            segment = path[len(prefix):]
            if path.startswith(prefix) and segment and "/" not in segment:
                return limit
        return self.max_body_bytes

    @staticmethod
    def _content_length(scope: dict[str, Any]) -> int | None:
        for name, value in scope.get("headers", ()):
            if name.lower() != b"content-length":
                continue
            try:
                parsed = int(value)
            except ValueError:
                return None
            return max(0, parsed)
        return None

    @staticmethod
    async def _reject(send) -> None:
        body = json.dumps({"detail": "request body is too large"}).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})
