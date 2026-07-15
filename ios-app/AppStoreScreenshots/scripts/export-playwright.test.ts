import assert from "node:assert/strict";
import test from "node:test";
import { isLoopbackTarget, shouldAllowRequest } from "./export-playwright";

test("accepts only loopback targets by default", () => {
  assert.equal(isLoopbackTarget(new URL("http://127.0.0.1:3000")), true);
  assert.equal(isLoopbackTarget(new URL("http://localhost:3000")), true);
  assert.equal(isLoopbackTarget(new URL("http://[::1]:3000")), true);
  assert.equal(isLoopbackTarget(new URL("https://example.com")), false);
  assert.equal(isLoopbackTarget(new URL("file:///tmp/screenshots.html")), false);
});

test("matches request origins exactly", () => {
  const target = new URL("http://127.0.0.1:3000");

  assert.equal(shouldAllowRequest("http://127.0.0.1:3000/_next/static/app.js", target, false), true);
  assert.equal(shouldAllowRequest("data:image/png;base64,AA==", target, false), true);
  assert.equal(shouldAllowRequest("blob:http://127.0.0.1:3000/id", target, false), true);
  assert.equal(shouldAllowRequest("http://127.0.0.1:3000@evil.example/collect", target, false), false);
  assert.equal(shouldAllowRequest("https://example.com/collect", target, false), false);
  assert.equal(shouldAllowRequest("https://example.com/collect", target, true), true);
});
