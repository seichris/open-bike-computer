from __future__ import annotations

import json
import unittest

from map_platform.request_limits import RequestBodyLimitMiddleware


class RequestBodyLimitMiddlewareTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_chunked_body_without_content_length(self):
        app_called = False

        async def app(scope, receive, send):
            nonlocal app_called
            app_called = True

        middleware = RequestBodyLimitMiddleware(app, max_body_bytes=5)
        request_messages = iter(
            [
                {"type": "http.request", "body": b"abc", "more_body": True},
                {"type": "http.request", "body": b"def", "more_body": False},
            ]
        )
        response_messages = []

        async def receive():
            return next(request_messages)

        async def send(message):
            response_messages.append(message)

        await middleware(
            {"type": "http", "method": "POST", "headers": []},
            receive,
            send,
        )

        self.assertFalse(app_called)
        self.assertEqual(response_messages[0]["status"], 413)
        self.assertEqual(
            json.loads(response_messages[1]["body"]),
            {"detail": "request body is too large"},
        )

    async def test_replays_a_body_within_limit(self):
        received_by_app = []

        async def app(scope, receive, send):
            while True:
                message = await receive()
                received_by_app.append(message)
                if not message.get("more_body", False):
                    break
            await send({"type": "http.response.start", "status": 204, "headers": []})
            await send({"type": "http.response.body", "body": b""})

        middleware = RequestBodyLimitMiddleware(app, max_body_bytes=6)
        original_messages = [
            {"type": "http.request", "body": b"abc", "more_body": True},
            {"type": "http.request", "body": b"def", "more_body": False},
        ]
        request_messages = iter(original_messages)
        response_messages = []

        async def receive():
            return next(request_messages)

        async def send(message):
            response_messages.append(message)

        await middleware(
            {"type": "http", "method": "POST", "headers": []},
            receive,
            send,
        )

        self.assertEqual(received_by_app, original_messages)
        self.assertEqual(response_messages[0]["status"], 204)


if __name__ == "__main__":
    unittest.main()
