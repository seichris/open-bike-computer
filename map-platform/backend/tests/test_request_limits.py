from __future__ import annotations

import asyncio
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

    async def test_replays_body_once_then_passes_original_events_through(self):
        upstream = asyncio.Queue()
        body_messages = [
            {"type": "http.request", "body": b"ab", "more_body": True},
            {"type": "http.request", "body": b"cd", "more_body": False},
        ]
        for message in body_messages:
            upstream.put_nowait(message)
        pulled = []

        async def receive():
            message = await upstream.get()
            pulled.append(message)
            return message

        seen = []
        response_messages = []

        async def app(scope, receive, send):
            while True:
                message = await receive()
                seen.append(message)
                if not message.get("more_body", False):
                    break
            # After the replayed body nothing is pending upstream: receive() must wait
            # for a real event instead of inventing an empty request.
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(receive(), timeout=0.05)
            upstream.put_nowait({"type": "http.disconnect"})
            seen.append(await asyncio.wait_for(receive(), timeout=1))
            # Later events are not swallowed either.
            upstream.put_nowait({"type": "http.disconnect", "later": True})
            seen.append(await asyncio.wait_for(receive(), timeout=1))
            await send({"type": "http.response.start", "status": 204, "headers": []})
            await send({"type": "http.response.body", "body": b""})

        async def send(message):
            response_messages.append(message)

        middleware = RequestBodyLimitMiddleware(app, max_body_bytes=10)
        await asyncio.wait_for(
            middleware({"type": "http", "method": "POST", "path": "/v1/jobs", "headers": []}, receive, send),
            timeout=2,
        )
        self.assertEqual(seen[:2], body_messages)  # Exact body, delivered once.
        self.assertEqual(b"".join(message["body"] for message in seen[:2]), b"abcd")
        self.assertEqual(seen[2:], [{"type": "http.disconnect"}, {"type": "http.disconnect", "later": True}])
        self.assertEqual(len(pulled), 4)  # Each upstream event was read exactly once.
        self.assertEqual(response_messages[0]["status"], 204)

    async def test_disconnect_during_body_is_replayed_then_live_events_follow(self):
        upstream = asyncio.Queue()
        for message in (
            {"type": "http.request", "body": b"ab", "more_body": True},
            {"type": "http.disconnect"},
        ):
            upstream.put_nowait(message)
        seen = []

        async def app(scope, receive, send):
            seen.append(await receive())
            seen.append(await receive())
            upstream.put_nowait({"type": "http.disconnect", "later": True})
            seen.append(await asyncio.wait_for(receive(), timeout=1))

        async def send(message):
            raise AssertionError("a disconnected request is not answered here")

        middleware = RequestBodyLimitMiddleware(
            app, max_body_bytes=1, body_limits={("PUT", "/v1/social/me/avatar"): 10})
        await asyncio.wait_for(
            middleware({"type": "http", "method": "PUT", "path": "/v1/social/me/avatar", "headers": []},
                       upstream.get, send),
            timeout=2,
        )
        self.assertEqual(seen, [
            {"type": "http.request", "body": b"ab", "more_body": True},
            {"type": "http.disconnect"},
            {"type": "http.disconnect", "later": True},
        ])


if __name__ == "__main__":
    unittest.main()
