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

    async def test_map_api_has_no_implicit_social_body_limit_bypass(self):
        calls=[]
        async def app(scope,receive,send): calls.append(scope['path'])
        for overrides,expected in [({},413),({('PUT','/v1/social/me/avatar'):10},None)]:
            for path in ['/v1/jobs','/v1/social/me/avatar']:
                responses=[]
                async def receive(): return {'type':'http.request','body':b'123456','more_body':False}
                async def send(message): responses.append(message)
                middleware=RequestBodyLimitMiddleware(app,max_body_bytes=5,body_limits=overrides)
                await middleware({'type':'http','method':'PUT','path':path,'headers':[]},receive,send)
                if ('PUT',path) in overrides:self.assertEqual(responses,[])
                else:self.assertEqual(responses[0]['status'],413)
        self.assertEqual(calls,['/v1/social/me/avatar'])


if __name__ == "__main__":
    unittest.main()
