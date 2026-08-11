# Bicino Real-Device Browser Debugging Implementation Plan

## Outcome

Add a development-only remote debugging surface for a real Bicino device. A
browser shows the framebuffer that the connected ESP32 most recently sent to
the AMOLED panel, and browser pointer input is delivered to the same LVGL UI
running on that physical device.

This is not a simulator. The device continues to run its real firmware, map
renderer, BLE session, GPS/navigation data, storage, display-power policy, and
screen state. The browser is a remote viewer and synthetic pointer source.

The first complete workflow is:

1. Flash a dedicated remote-debug firmware profile for the exact 1.75-inch or
   2.06-inch board.
2. Authenticate the iPhone app to that Bicino over the existing BLE ownership
   protocol.
3. Start **Remote Device Debugging** from Developer Settings. The authenticated
   BLE control plane sends the optional Keychain-backed LAN credentials for this
   session, then returns the selected transport, SSID, base URL, and random
   session token.
4. Keep the Mac on that LAN when it is reachable, or join the advertised Bicino
   access point after automatic fallback, then open the supplied URL in Brave.
   The token lives in the URL fragment, which is not sent in the initial HTTP
   request; the page keeps it in memory and applies it only as the existing
   transfer-auth header.
5. View the real device frame, tap, long-press, or drag in the browser, and see
   the resulting real-device frame.
6. Save the canvas as PNG or use the repository CLI to capture frames and send
   deterministic input for automated debugging.
7. End the session explicitly, or let the existing five-minute authorized-
   traffic timeout stop the HTTP server and active Wi-Fi transport after the
   browser disappears.

## Baseline

This plan was prepared from freshly fetched `origin/main` at
`b0d561f027c87f195fa27a9ee822c7d48cc59326`.

### Display path

The current Waveshare firmware already contains the pixels needed for remote
viewing:

- Both targets use LVGL 9 with RGB565 and `LV_DISPLAY_RENDER_MODE_FULL`.
- The 1.75-inch target is `466 x 466`, or `434,312` framebuffer bytes.
- The 2.06-inch target is `410 x 502`, or `411,640` framebuffer bytes.
- `my_disp_flush()` writes those pixels to the CO5300 panel.
- The 1.75-inch target keeps the CO5300 in its verified native orientation and
  software-rotates every LVGL frame into `disp_rotation_buf` before the panel
  write. Capturing `disp_draw_buf` would therefore be the wrong visual
  orientation; the remote view must copy the final `pixels`/`targetW`/`targetH`
  values after software rotation.
- The 2.06-inch target writes the LVGL buffer in native orientation and then
  performs its required one-pixel commit write. The copied frame is still the
  full panel-oriented image.
- `displayFlushCount`, last/max flush timing, display-power state, and firmware
  identity are already observable and can seed debug metadata.

The panel driver currently owns one full LVGL draw buffer on both targets and a
second full software-rotation buffer on the 1.75-inch target. The remote viewer
needs one additional, session-scoped snapshot buffer so network transmission
cannot race LVGL rendering or rotation.

`LV_USE_SNAPSHOT` remains disabled. It does not need to be enabled: copying the
existing final flush buffer is cheaper, includes the actual rotation path, and
does not require LVGL to rerender the object tree into another image.

### Touch and UI scheduling path

The current input path is also suitable for controlled injection:

- The CST9217 path publishes a validated two-contact `TouchFrame` for the
  1.75-inch device.
- The FT3168 path publishes a compatible single-contact frame for the 2.06-inch
  device.
- Hardware coordinates are transformed into logical LVGL coordinates in
  `my_touchpad_read()`.
- `lv_timer_handler()` runs on the main UI task. Network work runs on the
  separate device-transfer HTTP task.
- `ui_scheduler` already wakes the UI task for BLE, touch, transfer, and other
  bounded work.

The HTTP task must never call LVGL or mutate the hardware touch globals. It will
enqueue validated synthetic pointer events, wake the UI task, and let
`my_touchpad_read()` consume them in order.

### Existing authenticated transfer transport

The generic device-transfer system already provides most of the secure local
transport:

- Authenticated BLE `DTRN` control selects a mutually exclusive transfer mode.
- `DSTS` returns the temporary base URL, access-point SSID, and 128-bit random
  session token.
- The token is required in `X-BikeComputer-Transfer-Token` for HTTP requests.
- A transfer generation revokes requests from an older session.
- The HTTP listener runs on a dedicated FreeRTOS worker and holds the existing
  transfer power lock.
- Request line/header/body bounds, unsupported transfer-encoding rejection,
  and response completion handling are already implemented.
- Only authorized traffic extends the five-minute transfer lifetime.
- Map and firmware handlers already share the server; a third
  `/device-debug` handler fits the existing four-handler bound.

This newer transfer server is independent of the disabled legacy IceNav CLI,
Telnet CLI, AsyncWebServer file manager, and stale `scshot` documentation. None
of those legacy paths should be revived.

### Missing pieces

Current `main` has no:

- session-safe framebuffer snapshot store;
- `debug` transfer mode or capability bit;
- browser page or frame wire format;
- remote pointer event queue/arbitration policy;
- iOS control for starting a browser-debug session; or
- host CLI for scripted screenshot/tap/swipe operations.

## Product contract

### Browser behavior

- The page identifies the exact real device before enabling input: target,
  firmware version/build, build profile, complete Git SHA, dimensions, pixel
  format, and session mode.
- The viewport preserves the device aspect ratio at any browser size.
- A frame is either complete and internally consistent or rejected. A torn
  mixture of two device frames must never be displayed.
- Pointer down, move, up, cancel, long-press, and one-finger drag work.
- Browser clicks use panel/display coordinates: the pixel clicked in the frame
  is the pixel targeted on the physical screen.
- Pointer input is disabled until an authenticated info response proves that
  the device is in `debug` mode and the target/dimensions are supported.
- The page shows frame sequence, capture age, display-power state, request
  latency, dropped/skipped capture count, and connection state without covering
  the viewport.
- **Save PNG** converts the already received RGB565 frame in the browser. The
  ESP32 does not spend heap or CPU on PNG encoding.
- The downloaded name includes target, short Git SHA, and frame sequence.
- **Wake Display** is explicit. Fetching frames does not silently wake the
  AMOLED or convert a hidden first touch into an accidental UI action.
- **End Session** receives a response before the device revokes the token and
  tears down its active Wi-Fi transport.

### Real-device semantics

- Navigation, BLE, map rendering, storage, buttons, and display inactivity keep
  running normally while the debugger is attached.
- Synthetic pointer input enters at the LVGL pointer boundary. It intentionally
  bypasses the CST9217/FT3168 controller and I2C transport.
- A real physical touch always overrides synthetic input. It cancels any
  injected pointer and blocks new remote input until all physical contacts are
  released.
- Ending, timing out, or revoking a session always generates a synthetic
  release/cancel before the input source is discarded.
- Browser frame polling counts as authorized transfer traffic and keeps the
  debug network session alive, but it does not count as rider interaction for
  the display inactivity timer.
- Accepted synthetic input does count as meaningful UI activity.
- The transfer power lock means this mode is unsuitable for battery-runtime or
  automatic-light-sleep characterization. The page and documentation must say
  so.

### Truth boundary

The browser shows the exact RGB565 bytes submitted to the panel after the
firmware's software rotation. It is still not optical panel readback.

It can validate:

- the active real-device UI and state;
- LVGL layout, map rendering, navigation data, and screen transitions;
- the firmware's final pixel orientation; and
- UI behavior in response to synthetic input.

It cannot validate:

- AMOLED power, brightness, burn-in, black-screen, green-edge, or physical
  clipping faults;
- corruption introduced after the framebuffer enters the CO5300/QSPI path;
- touch-controller electrical behavior, interrupt timing, I2C recovery, or
  physical calibration; or
- the appearance of direct panel writes that bypass the runtime LVGL flush.

Those cases still require a camera/eyes and physical touch evidence. The UI
must label its input **Synthetic pointer** rather than **Touch test**.

## Decisions locked into this plan

1. This is a remote view/controller for real hardware, not an LVGL desktop
   simulator.
2. Reuse the authenticated generic transfer server, preferring a configured
   normal LAN and retaining the temporary Bicino access point as fallback. Do
   not re-enable the legacy CLI or AsyncWebServer.
3. Ship only in dedicated `*_REMOTE_DEBUG` firmware profiles guarded by
   `DEVICE_REMOTE_DEBUG=1`. Production profiles neither register the handler nor
   advertise the capability.
4. Use authenticated BLE as the session control plane and HTTP/Wi-Fi as the
   framebuffer/input data plane.
5. Serve a small same-origin browser client from the ESP32. Do not depend on a
   CDN, package registry, internet connection, or a second local web server.
6. Capture the panel-oriented buffer passed to `gfx->writePixels()`, after the
   1.75-inch software rotation.
7. Allocate one snapshot buffer only while debug mode is entering. Fail closed
   before enabling Wi-Fi if a full contiguous snapshot cannot be allocated.
8. Never stream directly from LVGL's draw buffer or the active rotation buffer.
9. Use one snapshot buffer plus non-blocking capture. Network transmission may
   cause a debug frame to be skipped, but must never block LVGL or the panel
   flush waiting for the browser.
10. Keep the first protocol single-pointer. It supports taps, long presses, and
    drags but does not claim remote two-finger pinch support.
11. Queue pointer events and consume them on the UI/LVGL task. The HTTP worker
    never calls LVGL.
12. Physical input wins over remote input.
13. Use short polling with a last-seen frame sequence. Do not add WebSockets or
    long polling to the current single HTTP worker in the first version.
14. Encode frames as a small versioned binary header plus raw RGB565. Convert to
    PNG only in the browser/host client.
15. Keep the token out of query parameters, HTTP logs, debug logs, downloaded
    filenames, and persistent browser storage.
16. Validate both display targets physically. A 1.75-only demonstration is not
    completion.

## Non-goals

- Running firmware or LVGL in a desktop simulator.
- Internet-accessible remote control or relay through the map backend.
- Shipping a remote-control service in production firmware.
- Arbitrary shell commands, memory access, file browsing, firmware upload, or
  JTAG control through the debug page.
- Streaming camera video or claiming optical verification.
- Replacing physical touch-controller tests.
- Audio streaming, microphone input, key injection, or multi-pointer gestures
  in version 1.
- Recording/replaying complete rides in the first implementation. The CLI
  primitives should make later replay possible without changing the device
  protocol.

## Proposed architecture

```text
Authenticated iPhone app
  DTRN enter|debug [optional bounded LAN credentials]
          |
          v
BLE transfer-control queue -----> main/UI task -----> debug session enable
                                                       |
                                                       v
                                         normal LAN or fallback AP + token
                                                       |
                         +-----------------------------+------------------+
                         |                                                |
                         v                                                v
             GET /device-debug/v1/frame                    POST /pointer or /wake
                         |                                                |
                         v                                                v
                stable snapshot buffer                        bounded event queue
                         ^                                                |
                         |                                                v
LVGL full frame -> optional 1.75 rotation -> panel write     UI-task input arbiter
                         |                                                |
                         +---- non-blocking snapshot copy                 v
                                                               my_touchpad_read()
                                                                        |
                                                                        v
                                                                    real LVGL UI
```

### Firmware modules

Add a focused `esp32/lib/device_debug/` module rather than growing the panel,
BLE, or generic HTTP files into a second application:

- `device_debug_protocol.hpp`
  - pure frame-header and pointer-message values;
  - bounded query/body validation;
  - panel-to-LVGL coordinate transformation;
  - no Arduino, Wi-Fi, or LVGL dependencies.
- `device_debug_frame_store.hpp/.cpp`
  - session-scoped PSRAM allocation;
  - snapshot metadata and sequence;
  - non-blocking producer lock and bounded consumer lock;
  - capture/skipped/error counters.
- `device_debug_input.hpp/.cpp`
  - fixed-capacity pointer queue;
  - event-order state machine and fail-safe release;
  - physical-input override and session cancellation;
  - UI-task-only consumption API.
- `device_debug_http.hpp/.cpp`
  - transfer-handler registration and mode checks;
  - static browser shell;
  - authenticated info/frame/input/wake/exit endpoints;
  - chunked socket writes directly from the stable snapshot without building a
    framebuffer-sized `std::string`.
- `device_debug_page.hpp` or an equivalently deterministic embedded asset
  - one self-contained HTML/CSS/JavaScript client;
  - compiled only into the remote-debug profiles.

Keep the panel integration to a narrow hook such as:

```cpp
device_debug::frameStore().offerPanelFrame(
    pixels,
    targetW,
    targetH,
    targetW * sizeof(uint16_t),
    millis());
```

Call it after the complete panel write/2.06 commit and before LVGL is told the
flush buffer is reusable. The hook returns immediately when debug mode is off,
the capture cadence is not due, or the snapshot is locked for transmission.

### Session-scoped frame store

The frame store owns one full-size RGB565 snapshot buffer:

| Target | Width | Height | Snapshot bytes |
| --- | ---: | ---: | ---: |
| `WAVESHARE_AMOLED_175` | 466 | 466 | 434,312 |
| `WAVESHARE_AMOLED_206` | 410 | 502 | 411,640 |

Entry rules:

1. Confirm the build has `DEVICE_REMOTE_DEBUG=1`.
2. Confirm the active display buffer is full-screen RGB565.
3. Record total free and largest contiguous PSRAM block.
4. Allocate the exact snapshot size from PSRAM with the same alignment policy
   used by the display buffers.
5. If allocation fails, free partial state, publish
   `remote_debug_insufficient_psram`, and do not enable transfer mode or Wi-Fi.
6. Mark the next eligible physical display flush for capture and notify the UI
   task to invalidate the active screen if no fresh frame is pending.

Capture rules:

- The producer attempts the snapshot lock with zero wait.
- If the browser is transmitting the prior snapshot, increment
  `skippedLocked` and return without delaying the display.
- Copy only a complete full-screen frame. Reject unexpected area, dimensions,
  stride, or pixel format and expose a structured capture error.
- Cap normal capture cadence with a named constant, initially 5 frames/second.
  Pointer acceptance and explicit capture requests may request the next frame,
  but never cause a second concurrent copy.
- Increment the independent frame sequence only after the full copy and
  metadata publication are complete.
- A consumer locks the stable buffer while streaming. The display producer
  skips frames rather than waiting.
- Compute the payload CRC on the HTTP worker after it has locked a stable
  snapshot. CRC work must not extend the panel flush path.
- Free the snapshot only after the HTTP worker has stopped and every consumer
  has released it.
- Session exit records before/after free and largest-block values so a leak or
  fragmentation regression is visible.

The initial frame is created through the UI task. The HTTP worker must not call
`lv_obj_invalidate()` directly.

### Binary frame contract

`GET /device-debug/v1/frame?after=<sequence>` returns `204 No Content` when the
client already has the newest frame. A new frame returns a fixed little-endian
header followed by exactly `payloadBytes` RGB565 bytes.

Proposed schema 1 header:

```text
Magic             4 bytes   ASCII "BCF1"
HeaderBytes       UInt16LE
Flags             UInt16LE  reserved, must be zero in schema 1
Sequence          UInt32LE
CapturedAtMs      UInt32LE  boot-relative millis
Width             UInt16LE
Height            UInt16LE
StrideBytes       UInt16LE
PixelFormat       UInt8     1 = RGB565 little-endian
Orientation       UInt8     0 = already panel-oriented
PayloadBytes      UInt32LE
PayloadCRC32      UInt32LE
RGB565 payload    payloadBytes
```

Requirements:

- `HeaderBytes` allows additive metadata in a later schema.
- The browser/CLI rejects unknown magic, undersized headers, unsupported pixel
  formats, impossible dimensions/stride, length mismatch, and CRC mismatch.
- HTTP `Content-Length` covers header plus payload.
- Response helpers gain explicit content type and safe additional response
  headers; they do not concatenate the pixel payload into a `std::string`.
- Network writes use bounded chunks and handle partial writes/disconnects.
- A failed or partial response leaves the prior browser frame visible and
  marked stale.

### HTTP API

All routes exist only while transfer mode is `debug`.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `GET` | `/device-debug/` | No token | Load the secret-free same-origin UI shell. |
| `GET` | `/device-debug/v1/info` | Token | Read identity, dimensions, display/session state, counters, and current frame sequence. |
| `GET` | `/device-debug/v1/frame?after=N` | Token | Read a new complete frame or receive `204`. |
| `POST` | `/device-debug/v1/pointer` | Token | Queue one bounded pointer event. |
| `POST` | `/device-debug/v1/display/wake` | Token | Queue an explicit display wake/full refresh on the UI task. |
| `POST` | `/device-debug/v1/button/boot` | Token | Queue one debounced BOOT/GPIO0 short press through the existing firmware button path. |
| `POST` | `/device-debug/v1/session/exit` | Token | Acknowledge, cancel input, then revoke the session after response completion. |

Pointer JSON schema:

```json
{
  "schema": 1,
  "eventSequence": 42,
  "pointerId": 0,
  "phase": "down",
  "x": 233,
  "y": 233
}
```

`phase` is `down`, `move`, `up`, or `cancel`. Version 1 accepts only pointer ID
`0`.

Endpoint rules:

- Require the exact existing transfer token header for every API call.
- Recheck authorization after reading a request body so revoked generations
  cannot queue input.
- Require `application/json`, an explicit content length, and a small fixed body
  limit for pointer requests.
- Reject duplicate/out-of-order sequences, move/up without a down, down while
  already down, coordinates outside the active panel, non-integral fields,
  unknown keys when they create ambiguity, and unsupported schemas.
- Rate-limit accepted pointer messages and frame responses with named,
  host-tested policies.
- The UI shell receives `Cache-Control: no-store`, `Referrer-Policy:
  no-referrer`, `X-Content-Type-Options: nosniff`, `frame-ancestors 'none'`, and
  a restrictive CSP. It contains no external URLs or executable dependencies.
- The token is read from `location.hash`, removed from the visible address bar
  with `history.replaceState`, retained only in page memory, and never written
  to `localStorage`, cookies, console output, or DOM text.

Do not use a long-held frame request: the current transfer server intentionally
has one HTTP worker. Short polling lets pointer requests interleave with frame
requests without adding a second concurrent network stack.

### Synthetic pointer state machine

Use a pure state machine with these states:

- `Idle`
- `RemotePressed`
- `PhysicalOverrideUntilRelease`
- `CancelPending`

Rules:

1. The HTTP worker validates and enqueues events in a fixed-capacity queue; it
   never updates `touchPressed`, `touchX`, `touchY`, `TouchFrame`, or LVGL.
2. `my_touchpad_read()` continues sampling physical hardware first so a rider
   can always take control.
3. If any physical contact is present, cancel the synthetic pointer and enter
   `PhysicalOverrideUntilRelease`.
4. While no physical contact is present, consume at most the next required
   synthetic transition per LVGL read. A queued down and up therefore appear to
   LVGL in separate samples and cannot collapse into no click.
5. Browser coordinates are panel-oriented. Convert them through the same pure
   rotation mapping used by hardware input before assigning the LVGL point.
6. Keep hardware `TouchFrame` snapshots and diagnostics hardware-only. Expose
   synthetic input through separate debug counters.
7. A browser-held pointer sends bounded heartbeat/move updates. If no update is
   received before the fail-safe interval, queue a release and record
   `pointer_timeout`.
8. Queue overflow rejects the HTTP request; it must not discard an older `up`
   or `cancel` and leave LVGL pressed.
9. Session exit, BLE revocation, transfer timeout, Wi-Fi teardown, and debug
   allocation failure all converge through one `cancelSession()` path.
10. Remote pointer acceptance notifies `ui_scheduler` with a new explicit
    `RemoteDebug` wake reason and records meaningful display activity on the UI
    task.

The state machine is independent of Arduino/LVGL and covered by host tests,
including sequence wraparound and cancellation races.

### Display wake behavior

Frame polling never wakes the AMOLED. If the display is dimmed or off:

- `/info` reports that state.
- the browser overlays **Display off** or **Display dimmed** on the last frame;
- pointer injection is rejected while off, avoiding an invisible activation;
- **Wake Display** queues the same policy-level meaningful activity used by a
  valid local wake and requests a full LVGL refresh; and
- the next complete physical flush becomes the next remote frame.

Do not manipulate the CO5300 or PMIC directly from the debug module.

### Browser client

Use platform APIs only:

- `fetch` with the transfer token header;
- `ArrayBuffer`/`DataView` for frame validation;
- `CanvasRenderingContext2D`/`ImageData` for RGB565 conversion;
- Pointer Events plus pointer capture for down/move/up/cancel;
- `requestAnimationFrame` only for browser drawing, not device polling; and
- `canvas.toBlob()` for PNG export.

The client:

- issues only one frame request at a time;
- polls at a bounded idle cadence and immediately requests a frame after an
  accepted pointer event;
- throttles pointer moves while preserving the final move/up;
- maps CSS coordinates to integer panel pixels using the canvas bounding rect,
  clamps them, and shows an optional crosshair;
- validates `/info` before enabling input;
- stops polling after repeated authorization/network failures and requires an
  explicit reconnect;
- never substitutes a stale target/dimension after reconnecting to a different
  device; and
- shows a permanent note that framebuffer and synthetic-pointer evidence are
  not panel/touch-hardware validation.

### iPhone developer control surface

Extend the existing Developer Settings rather than adding a production-facing
device setting.

Add a **Remote Device Debugging** section that:

- appears only in an iOS Debug build;
- requires authenticated navigation readiness and the negotiated remote-debug
  capability bit;
- sends plain `DTRNenter|debug` for hotspot-only use or the versioned bounded
  LAN-credential envelope for LAN-first use, then requires a fresh `DSTS` whose
  mode is exactly `debug`, base URL is present, and token is non-empty;
- does not use the map/firmware fallback modes;
- stores the preferred LAN only in this iPhone's device-only Keychain and never
  copies or logs the password;
- verifies a reported LAN endpoint and restarts the debug session on the device
  hotspot when association or endpoint reachability fails;
- displays target, transport, SSID, base URL, fallback state, and session status;
- offers **Copy Browser URL** using
  `<baseUrl>/device-debug/#<sessionToken>`;
- offers **Copy Session Details** without writing them into the persistent BLE
  debug log;
- offers **End Debug Session** using `DTRNexit`; and
- clears token-bearing UI/clipboard guidance when the session ends or is
  replaced.

Add `debug` to `DeviceTransferSession.Mode`, but keep map and firmware network-
join behavior unchanged. The debug preparation path obtains and verifies the
BLE session details without automatically moving the iPhone onto the access
point; the Mac is the intended browser host. On a LAN result it stays on the
normal network. On a hotspot result the Mac joins the advertised accessory AP.

### BLE capability and mode contract

- Add `REMOTE_DEVICE_DEBUG_FEATURE = 1 << 16` to CAP2 and advance the client
  capability version.
- Set the bit only when `DEVICE_REMOTE_DEBUG=1` and the frame/input services
  initialized successfully.
- Extend `ble_transfer::Action` with `EnableDebug` and cover merge/replacement
  behavior in `test_transfer_control_dispatch.cpp`.
- Accept plain `DTRNenter|debug` and the versioned LAN-first credential envelope
  only after BLE authentication and only when the capability is available.
- Keep LAN credentials session-scoped in RAM, exclude the password from every
  status/log surface, attempt station mode for six seconds on the HTTP worker,
  and start the device AP when station association fails.
- Keep modes mutually exclusive. An active `map` or `firmware` session returns
  `transfer_busy`; an existing `debug` session may return a fresh status without
  silently rotating its token unless a new transfer boundary is requested.
- Allocate the frame store before `deviceTransferHttp.setEnabled(true,
  "debug")`. If allocation fails, publish the structured error over `DSTS` and
  leave Wi-Fi off.
- Add a mode-aware transfer teardown dispatcher instead of allowing generic
  `setEnabled(false)` calls to bypass mode-owned cleanup. BLE exit, the existing
  inactivity timeout, the browser exit endpoint, mode replacement, and setup
  failure all route through it. For debug mode it revokes the transfer
  generation first, cancels input, stops the worker, waits for snapshot
  consumers, then frees the snapshot. Existing map activation and firmware
  response-completion semantics remain unchanged.
- Update [the BLE protocol](../ble-protocol.md) in the implementation change.

## Host automation client

Add `esp32/tools/device_debug.py` using the Python standard library where
practical. It operates against an already established debug session and offers:

```text
info
screenshot --output PATH.png
tap X Y
long-press X Y --duration-ms N
swipe X1 Y1 X2 Y2 --duration-ms N
wake
exit
```

Requirements:

- Read the token from an interactive prompt, a mode-`0600` session file, or a
  task-specific environment variable; do not require it on the command line
  where it appears in process listings.
- Redact the token from errors and logs.
- Validate device identity/dimensions before sending input.
- Validate frame header, payload length, and CRC before writing a PNG.
- Implement the minimal RGB565-to-PNG conversion with bounded row buffers; do
  not require Pillow merely for a screenshot.
- Use monotonic input sequences and explicit cancel on interruption.
- Return non-zero on stale/no frame, authorization failure, mismatched device,
  rejected input, or invalid PNG output.

This CLI is the automation seam for Codex and regression scripts. It does not
discover, pair, flash, or select a physical board; those remain explicit
operator steps under the repository's device-identity rules.

## Implementation phases

### Phase 1: Pure protocol and policy types

Add the host-testable frame header, pointer schema/state machine, coordinate
mapping, capture cadence, and bounds policies.

Files:

- `esp32/lib/device_debug/device_debug_protocol.hpp`
- `esp32/lib/device_debug/device_debug_input.hpp`
- `esp32/tools/tests/test_device_debug_protocol.cpp`
- `esp32/tools/tests/test_device_debug_input.cpp`
- `.github/workflows/ci.yml`

Acceptance:

- RGB565 header encoding/decoding is byte-exact.
- Both target dimensions and 0/90-degree mappings cover corners, edges, and
  center pixels.
- Invalid fields, sequence ordering, queue overflow, timeout, session cancel,
  and physical override are deterministic.

### Phase 2: Session-scoped panel-frame capture

Add the snapshot store and the narrow post-panel-write hook.

Files:

- `esp32/lib/device_debug/device_debug_frame_store.hpp/.cpp`
- `esp32/lib/panel/WAVESHARE_AMOLED_175.cpp`
- `esp32/lib/panel/WAVESHARE_AMOLED_175.hpp`
- memory/observability host policies and tests

Acceptance:

- The 1.75 frame is copied from the software-rotated buffer.
- The 2.06 frame is copied from the native full frame after its commit write.
- A locked snapshot increments a skip counter and never stalls display flush.
- Debug-off overhead is one predictable branch and no allocation.
- Entry fails closed when full-frame capture cannot be guaranteed.

### Phase 3: Debug HTTP service and browser asset

Register the handler, implement the versioned endpoints, add safe binary
response streaming, and embed the offline page.

Files:

- `esp32/lib/device_debug/device_debug_http.hpp/.cpp`
- `esp32/lib/device_debug/device_debug_page.hpp`
- narrow response-header support in
  `esp32/lib/device_transfer/device_transfer_http.*`
- `esp32/src/main.cpp`
- HTTP policy/security tests

Acceptance:

- Missing/wrong/revoked tokens fail.
- Wrong transfer mode fails.
- The UI shell contains no secret and no external dependency.
- Frame responses do not allocate or concatenate another full frame.
- Partial client disconnect releases the snapshot lock.
- `session/exit` tears down only after its response completion boundary.

### Phase 4: UI-task pointer and display-wake integration

Wire the pure input state into `my_touchpad_read()` and main-task activity/wake
handling.

Files:

- `esp32/lib/device_debug/device_debug_input.cpp`
- `esp32/lib/panel/WAVESHARE_AMOLED_175.cpp`
- `esp32/lib/ui_scheduler/ui_scheduler_policy.hpp`
- `esp32/src/main.cpp`
- scheduler/input host tests

Acceptance:

- Down and up are visible to LVGL on separate reads.
- A real touch cancels and suppresses the remote pointer until release.
- Every session termination path releases LVGL input.
- Frame polling does not wake the display; explicit wake does.

### Phase 5: BLE control, capability, and dedicated profiles

Add authenticated `debug` mode, capability negotiation, and two opt-in build
profiles.

Files:

- `esp32/lib/ble_navigation/ble_navigation.cpp`
- `esp32/lib/ble_navigation/transfer_control_dispatch.hpp`
- `esp32/lib/ble_navigation/device_capabilities_protocol.hpp`
- `esp32/platformio.ini`
- the mode-aware transfer teardown path in `esp32/src/main.cpp`
- `docs/firmware-build-profiles.md`
- `.github/workflows/ci.yml`

Profiles:

- `WAVESHARE_AMOLED_175_REMOTE_DEBUG`
- `WAVESHARE_AMOLED_206_REMOTE_DEBUG`

Both extend their ordinary developer/diagnostic target and add only
`DEVICE_REMOTE_DEBUG=1` plus the embedded page. They remain absent from release
workflows.

Acceptance:

- Both profiles build through `tools/build_firmware.py`.
- Both production binaries lack the remote-debug capability and route strings.
- Map, firmware, and debug modes remain mutually exclusive and revocable.

### Phase 6: iOS Developer Settings flow

Add the capability, handshake, token-safe UI, and exit flow.

Files:

- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift`
- `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift`
- `ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift` if the
  shared capability model lives there
- portable Swift tests

Acceptance:

- A stale `DSTS` cannot complete a new debug handshake.
- Debug mode never falls back to map mode.
- Tokens are not written to persistent logs.
- The section is absent from Release builds and disabled for unsupported
  firmware.

### Phase 7: Host CLI and browser verification

Add the scriptable client, PNG conversion tests, and browser contract checks.

Files:

- `esp32/tools/device_debug.py`
- `esp32/tools/tests/test_device_debug.py`
- static-page contract test ensuring no external resources and current API
  paths/schema

Acceptance:

- Known RGB565 color fixtures produce byte-valid PNGs with exact decoded
  colors.
- Script interruption sends cancel when possible.
- Token redaction and device-identity mismatch paths are tested.

### Phase 8: Documentation and physical validation

Update:

- `docs/ble-protocol.md`
- `docs/firmware-build-profiles.md`
- `docs/README.md`
- a new remote-debug operating guide with activation, Brave usage, CLI usage,
  identity checks, and the framebuffer/touch truth boundary

Then complete the physical matrix below. Do not mark the feature complete from
CI or simulator evidence alone.

## Test strategy

### Host and CI tests

Add deterministic coverage for:

- frame header layout, sequence wrap, size arithmetic, and CRC;
- RGB565 conversion fixtures;
- 1.75 and 2.06 panel/logical coordinate transforms;
- pointer ordering, click separation, move coalescing, timeout, overflow,
  cancel, and physical override;
- capture cadence and non-blocking skip policy;
- URL target/query bounds;
- transfer action merge/replacement with `EnableDebug`;
- capability presence only under the debug macro;
- unauthorized, wrong-mode, revoked-generation, malformed-body, oversized-body,
  out-of-range coordinate, and rate-limit decisions;
- debug handshake freshness and token redaction in Swift; and
- absence of debug handler/capability/page strings from production artifacts.

CI builds both new remote-debug profiles and preserves the existing normal,
metrics, light-sleep, and production matrix.

### Browser checks

Use Brave through the Codex extension, as required by repository workflow.

- Page loads with the Mac disconnected from the internet.
- CSP produces no violations.
- Token disappears from the address bar and never appears in console/network
  URLs.
- Resizing and Retina scaling preserve exact coordinate mapping.
- Pointer cancellation occurs when the window loses focus, pointer capture is
  lost, Escape is pressed, or the request fails.
- Save PNG matches the displayed canvas and its metadata filename.
- Reconnecting to a different target forces a fresh `/info` validation.

### Physical hardware matrix

Before any build/upload/device-debug action, identify the connected physical
device and its stable USB serial as required by `AGENTS.md`. Build and flash the
matching profile with `tools/build_firmware.py`; do not infer target from a
transient `/dev/cu.usbmodem*` path.

Run the complete matrix on both:

- Waveshare AMOLED 1.75, 466 x 466, software-rotated flush.
- Waveshare AMOLED 2.06, 410 x 502, native flush plus commit write.

For each target:

1. Confirm `BOOT_META` identifies the exact Git SHA, canonical target, and
   remote-debug build profile.
2. Start debug mode through an authenticated iPhone session and verify the
   browser identity before enabling input.
3. Compare browser output with a physical photo/view for orientation, all four
   corners, text direction, major colors, and clipping.
4. Exercise waiting, Map, Navigation, Ride Stats, Map + Navigation, Battery,
   settings/overlays, and any screen enabled by the tested firmware.
5. Tap controls near all edges and center; long-press; drag the map in every
   direction; cancel a drag; and verify the physical display and browser reach
   the same state.
6. Begin a remote press, then touch the physical panel. Verify physical override
   and clean remote suppression until release.
7. Dim and turn off the display. Verify polling does not wake it, remote input
   is rejected while off, and explicit Wake produces a fresh full frame.
8. Continue authenticated BLE GPS/navigation/route updates while repeatedly
   fetching frames and sending input.
9. Exercise the heaviest supported map, labels/buildings, route overlay, and UI
   combination. Record total/largest PSRAM before entry, during viewing, and
   after exit.
10. Stream at the browser's maximum supported cadence for at least 30 minutes;
    verify no watchdog, reboot, heap corruption, stuck pointer, torn frame, BLE
    loss, SD error, or unbounded memory decline.
11. Close the browser without exiting. Verify the session and active Wi-Fi
    transport stop after the five-minute inactivity boundary and the pointer is
    released.
12. Attempt map/firmware transfer while debug mode is active and vice versa;
    require a structured busy rejection with no mode confusion.

### Performance evidence

Record, rather than infer:

- snapshot `memcpy` duration distribution;
- panel flush duration with debug off, debug idle, and active capture;
- skipped-locked and skipped-cadence counts;
- HTTP frame bytes and response duration;
- browser tap-to-accepted-input latency;
- browser tap-to-updated-frame latency;
- UI loop maximum gap;
- free heap, total free PSRAM, and largest free PSRAM block; and
- BLE connection/auth/navigation counters during the soak.

Initial acceptance budgets, subject to tightening with baseline evidence:

- debug-off flush behavior is unchanged within measurement noise;
- an idle debug session that is not copying a frame adds no blocking work to a
  panel flush;
- a locked network snapshot causes a skipped debug frame, never a waiting UI
  task;
- p95 tap-to-updated-browser-frame is at most 750 ms on the local network;
- no single capture copy adds more than 30 ms to the flush path;
- the exact snapshot allocation is recovered on session exit without a
  persistent decline in the largest contiguous PSRAM block; and
- no torn frame is observed across at least 1,000 validated frames per target.

If hardware cannot meet a budget, capture the measured reason and revise the
architecture or explicitly review the budget. Do not silently remove the gate.

## Security and failure handling

- Production firmware has no remote-debug route or capability.
- Starting debug mode requires the existing authenticated BLE ownership
  session.
- The HTTP token remains random, boot/session-local, revocable, and delivered
  only in protected BLE status.
- The unauthenticated HTML shell contains no device identity, framebuffer, or
  secret. Every state/control API is token-protected.
- Unauthorized requests do not extend the session timeout.
- All request sizes, methods, content types, coordinates, sequences, and rates
  are bounded before queueing work.
- Session exit/replacement increments the transfer generation before cleanup.
- A stale HTTP worker cannot publish input into a newer session.
- A client disconnect while streaming releases its snapshot lock.
- A queue overflow fails the request and preserves the release/cancel path.
- A display/capture allocation failure leaves Wi-Fi off.
- Browser polling failure never changes device state.
- The page exposes no arbitrary URL fetch, file path, script execution, console,
  or firmware-update bridge.
- Debug status and logs redact tokens and pointer coordinates by default; an
  explicit diagnostics profile may rate-limit coordinate logging.

## Risks and mitigations

### PSRAM pressure

The extra 412-434 KiB snapshot competes with map and display buffers.

Mitigation: allocate only at session entry, inspect the largest contiguous
block, fail before Wi-Fi enable, test the heaviest map state, and free only after
the worker/consumer stops.

### Flush latency

A full framebuffer copy occurs on the display path.

Mitigation: cap cadence, copy only in debug mode, measure copy time, and use a
zero-wait producer lock. Never wait for network transmission.

### Single HTTP worker starvation

A long frame response can delay a pointer request.

Mitigation: short polling, bounded chunk writes, one in-flight browser frame,
pointer move throttling, no long poll/WebSocket in v1, and measured latency
gates.

### Stuck synthetic press

Browser loss after `down` could leave LVGL pressed.

Mitigation: bounded heartbeat timeout, focus/pointer-capture cancel, physical
override, and one shared session-cancel path for every teardown.

### Coordinate mismatch

The 1.75 display is software-rotated during flush.

Mitigation: capture post-rotation panel pixels, treat browser coordinates as
panel coordinates, share a pure inverse transform with hardware touch, and
physically validate corners on both targets.

### Misleading hardware evidence

A correct framebuffer can coexist with a broken panel or touch controller.

Mitigation: permanent truth-boundary copy in the page/guide and separate
camera/physical-touch acceptance evidence.

## Definition of done

The plan is fully implemented only when:

- both dedicated remote-debug profiles build from a clean exact Git identity;
- production profiles provably omit the capability, handler, and page;
- authenticated iOS Developer Settings can start and end a fresh debug session
  without leaking its token;
- Brave shows a validated, tear-free, panel-oriented frame from each physical
  target;
- browser and CLI tap/long-press/swipe operations control the real LVGL UI;
- physical touch override, display wake, cancellation, transfer exclusivity,
  and five-minute timeout behave as specified;
- host, Swift, security, artifact-absence, and browser tests pass;
- both physical-device soak/performance/memory matrices pass with recorded
  evidence; and
- protocol, build-profile, operating-guide, and truth-boundary documentation
  are current.

Green CI without the two physical-device matrices is not completion.
