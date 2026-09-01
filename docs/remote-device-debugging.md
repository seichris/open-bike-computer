# Remote device debugging

This facility shows and controls the currently connected physical Bicino in an
ephemeral in-app web view. It is not a simulator. The framebuffer, HTTPS
service, and synthetic
pointer input are compiled into two opt-in firmware profiles:

- `WAVESHARE_AMOLED_175_REMOTE_DEBUG`
- `WAVESHARE_AMOLED_206_REMOTE_DEBUG`

Flash the profile matching the physical panel. It contains the same application
firmware being tested plus `DEVICE_REMOTE_DEBUG=1`; the browser service cannot
be attached to an arbitrary already-flashed firmware image. Production and
ordinary developer builds do not contain the browser page, do not advertise
CAP2 bit `16`, and reject debug-mode entry.

## Start a session

1. Identify the connected panel and its stable USB hardware serial first; do
   not infer either from a transient `/dev/cu.usbmodem*` path. Build and flash
   the matching remote-debug profile using the repository's
   `esp32/tools/build_firmware.py` workflow and its explicit device selection.
2. Connect the iPhone app and complete normal authenticated navigation setup.
3. In a Debug build of the iPhone app, open **Developer Settings** and then
   **Remote Device Debugging**.
4. Leave **Prefer Local Wi-Fi** enabled and enter the normal 2.4 GHz network's
   SSID and password. The app stores them only in this iPhone's device-only
   Keychain. Clear the fields or turn the preference off to start directly on
   the device hotspot.
5. Tap **Start Remote Debugging**. The credentials are sent through the
   authenticated BLE session and retained only in device RAM. The device tries
   the LAN for six seconds, then starts `BikeComputer-Transfer` automatically
   if association fails. The app requires a fresh BLE `DSTS` response and also
   forces hotspot fallback if the device joined the LAN but the authenticated
   HTTPS endpoint is unreachable from the iPhone.
6. For **Device hotspot**, the app joins the displayed
   `BikeComputer-Transfer` network using its per-session password. For
   **Local Wi-Fi**, the iPhone remains on the configured LAN.
7. Tap **Open Secure Debug Console**. The app validates the exact TLS leaf pin
   delivered over authenticated BLE, loads only the fixed device page in a
   nonpersistent `WKWebView`, then injects the transfer token directly into page
   memory. The token is never placed in a URL, browser history, copied session
   details, or the clipboard. The page has no external resources.

The normal LAN password is never included in `DSTS`, the debug `/info` response,
copied session details, or firmware/iOS logs. ESP32-S3 station mode supports
ordinary 2.4 GHz personal/open networks, not captive portals or enterprise
authentication. Network client isolation or a firewall can also make the LAN
endpoint unreachable; those cases use the same hotspot fallback.
The iPhone shows a persistent fallback reason distinguishing a missing SSID,
authentication failure, association timeout, and an unreachable LAN endpoint.

The fallback hotspot uses a fresh WPA2 password for every debug session. That
password is returned only by authenticated BLE `DSTS`, is not exposed by the
HTTPS API, and is revoked with the session. Hotspot and LAN modes both use the
same device-local P-256 TLS identity and exact BLE-delivered leaf-certificate
pin. Redirects, host changes, and certificate changes fail closed.

The browser displays target identity, dimensions, display state, frame/copy and
HTTP-duration counters, PSRAM allocation evidence, the live user-oriented
RGB565 framebuffer, pointer control, an authenticated **BOOT (short press)**
action, an explicit wake action, PNG export, and session exit. The 1.75-inch
panel's final raw framebuffer is rotated 90 degrees left for display, and
browser coordinates are transformed back before the firmware applies its
normal panel-to-LVGL mapping. The 2.06-inch view remains unrotated. Frame
polling does not wake an off or dimmed panel. Pointer events are rejected while
the display is off;
**Wake display** requests the same policy-level activity and full refresh used
by local wake handling.

The remote-debug HTTP worker keeps its session-long stack in PSRAM so the
diagnostic service does not consume BLE/TLS internal-DMA headroom. Map and
firmware transfer workers retain internal stacks because activation and flash
paths have stricter memory-access requirements; the optimization is therefore
debug-mode-only and does not change release or update behavior.

Authorized HTTP/1.1 debug requests may reuse one bounded pinned-TLS connection;
each request still carries and independently validates the in-memory transfer
token and current session generation. This avoids repeated handshake allocation
and CPU churn during renderer sweeps. Token-free, malformed, revoked, and
explicit `Connection: close` requests close after one response, as does session
exit so its TLS close-notify remains the teardown boundary. A BLE disconnect or
mode revocation interrupts the active socket immediately rather than waiting
for the persistent connection's header timeout. Map installation, diagnostics
delivery, and firmware update modes retain their one-request close-and-commit
semantics.

**BOOT (short press)** queues one debounced short press through the same
firmware path as the physical GPIO0 button. It advances screens normally and,
if an ownership comparison is active, obeys the same fresh-input gate before
confirming it. Long-press owner recovery remains physical-only.

Physical touch always wins. Any hardware contact cancels the synthetic pointer
and suppresses remote input until physical release. Remote presses also have a
fail-safe timeout, and every session teardown path forces a release.
Pointer clients seed their event sequence from `/info`, so reconnecting the
page or running a new one-shot CLI command cannot replay an older sequence.

Keep the authenticated iPhone connected over BLE for the whole debug session;
a BLE disconnect immediately revokes browser authorization. Use **End Debug
Session** when finished. If a browser disappears without
exiting, the ordinary five-minute transfer inactivity boundary revokes the
credential, stops the active Wi-Fi transport, releases synthetic input, and
frees the snapshot.

## HTTPS contract

The token-free `GET /device-debug/` response is a secret-free, offline,
same-origin page. All versioned API routes require the existing
`X-BikeComputer-Transfer-Token` header:

| Method | Route | Result |
| --- | --- | --- |
| `GET` | `/device-debug/v1/info` | Target, identity, dimensions, display/network state, sequence, and counters. |
| `GET` | `/device-debug/v1/metrics` | One bounded schema-1 renderer/RAM snapshot; responses are limited to four per second. |
| `POST` | `/device-debug/v1/metrics/window` | Queue one validated renderer profile and fixture identity for the UI task, at most once per second; the active map ID and manifest receipt must match before it is applied. |
| `GET` | `/device-debug/v1/frame?after=N` | `204` if unchanged; otherwise one `BCF1` header and RGB565 payload. Benchmark clients may add `capturedAtOrAfter=M`; a buffered frame older than that wrap-safe device-uptime timestamp produces `204` and arms a fresh capture instead of transferring stale pixels. |
| `POST` | `/device-debug/v1/pointer` | Queue one schema-1 down/move/up/cancel event. |
| `POST` | `/device-debug/v1/display/wake` | Queue a UI-task display wake and full refresh. |
| `POST` | `/device-debug/v1/button/boot` | Queue one debounced BOOT/GPIO0 short press through the normal firmware path. |
| `POST` | `/device-debug/v1/session/exit` | Revoke the session after the response is consumed. |

The 32-byte little-endian `BCF1` header contains header size, flags, frame
sequence, capture time, width, height, stride, pixel format (`1` for RGB565LE),
orientation (`0` for panel-oriented), payload size, and payload CRC32. Consumers
must validate every field, exact response length, and CRC before displaying or
saving the frame.

The flush producer never waits for the HTTP worker. It copies at most five
complete frames per second into one session-scoped PSRAM snapshot. If the
browser holds that snapshot for transmission, the physical display completes
normally and the capture is counted as skipped.

## Automation CLI

`esp32/tools/device_debug.py` operates only on an already-established secure
session. The ordinary app flow intentionally does not export the token. For a
separately authorized automation harness, provide the HTTPS origin, exact leaf
pin, and token through task-specific environment variables or a mode-`0600`
JSON file with `baseUrl`, `tlsCertificateSha256`, and `token` fields. The client
disables ambient proxies, blocks redirects, completes and verifies the TLS
handshake before sending the token, and refuses plaintext origins:

```sh
cd esp32
BICINO_DEVICE_DEBUG_TOKEN='0123456789abcdef0123456789abcdef' \
  BICINO_DEVICE_DEBUG_TLS_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  python3 tools/device_debug.py --base-url https://192.168.4.1:8080 info
BICINO_DEVICE_DEBUG_TOKEN='0123456789abcdef0123456789abcdef' \
  BICINO_DEVICE_DEBUG_TLS_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  python3 tools/device_debug.py --base-url https://192.168.4.1:8080 \
  screenshot --output /tmp/bicino.png
```

Other commands are `metrics`, `begin-window`, `tap X Y`, `long-press X Y --duration-ms N`,
`swipe X1 Y1 X2 Y2 --duration-ms N`, `boot`, `wake`, and `exit`. The CLI validates the
device identity/dimensions before input and validates frame metadata, length,
CRC, and PNG output. It never discovers, selects, flashes, or pairs hardware.

For repeatable 3D-building profile sweeps, fixture replay, RAM/performance
gates, balanced runs, screenshots, soak testing, and ordinary-firmware
confirmation, use the [renderer building benchmark](renderer-benchmark.md)
runner instead of assembling individual CLI calls.

## Evidence boundary

The captured bytes prove what the firmware intended to present after its
target-specific framebuffer rotation and physical panel write. Synthetic input
proves LVGL behavior. Neither proves that AMOLED pixels emitted light at the
same colors nor that the capacitive touch controller detected a real finger.
Keep optical and physical-touch checks in the hardware validation matrix.
