# Remote device debugging

This facility shows and controls the currently connected physical Bicino in a
browser. It is not a simulator. The framebuffer, HTTP service, and synthetic
pointer input are compiled into two opt-in firmware profiles:

- `WAVESHARE_AMOLED_175_REMOTE_DEBUG`
- `WAVESHARE_AMOLED_206_REMOTE_DEBUG`

Flash the profile matching the physical panel. It contains the same application
firmware being tested plus `DEVICE_REMOTE_DEBUG=1`; the browser service cannot
be attached to an arbitrary already-flashed firmware image. Production and
ordinary developer builds do not contain the browser page, do not advertise
CAP2 bit `15`, and reject debug-mode entry.

## Start a session

1. Identify the connected panel and its stable USB hardware serial first; do
   not infer either from a transient `/dev/cu.usbmodem*` path. Build and flash
   the matching remote-debug profile using the repository's
   `esp32/tools/build_firmware.py` workflow and its explicit device selection.
2. Connect the iPhone app and complete normal authenticated navigation setup.
3. In a Debug build of the iPhone app, open **Developer Settings** and then
   **Remote Device Debugging**.
4. Tap **Start Remote Debugging**. The app requires a fresh BLE `DSTS` response
   for `debug` mode; cached transfer credentials are not accepted.
5. Join the displayed `BikeComputer-Transfer` Wi-Fi network on the Mac.
6. Tap **Copy Browser URL** and open it in Brave (through the Codex browser
   extension for automated checks). The token follows `#` and stays in page
   memory; do not put that URL in logs or screenshots. The page has no external
   resources, so losing internet connectivity while joined to the accessory AP
   does not affect it.

The browser displays target identity, dimensions, display state, frame/copy and
HTTP-duration counters, PSRAM allocation evidence, the live panel-oriented
RGB565 framebuffer, pointer control, an explicit wake action, PNG export, and
session exit. Frame polling does not wake an off or dimmed panel. Pointer events
are rejected while the display is off;
**Wake display** requests the same policy-level activity and full refresh used
by local wake handling.

Physical touch always wins. Any hardware contact cancels the synthetic pointer
and suppresses remote input until physical release. Remote presses also have a
fail-safe timeout, and every session teardown path forces a release.

Use **End Debug Session** when finished. If a browser disappears without
exiting, the ordinary five-minute transfer inactivity boundary revokes the
credential, stops the access point, releases synthetic input, and frees the
snapshot.

## HTTP contract

The unauthenticated `GET /device-debug/` response is a secret-free, offline,
same-origin page. All versioned API routes require the existing
`X-BikeComputer-Transfer-Token` header:

| Method | Route | Result |
| --- | --- | --- |
| `GET` | `/device-debug/v1/info` | Target, identity, dimensions, display state, sequence, and counters. |
| `GET` | `/device-debug/v1/frame?after=N` | `204` if unchanged; otherwise one `BCF1` header and RGB565 payload. |
| `POST` | `/device-debug/v1/pointer` | Queue one schema-1 down/move/up/cancel event. |
| `POST` | `/device-debug/v1/display/wake` | Queue a UI-task display wake and full refresh. |
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

`esp32/tools/device_debug.py` operates on an already-established session. Pass
the base URL separately and provide the secret through an interactive prompt,
the task-specific `BICINO_DEVICE_DEBUG_TOKEN` environment variable, or a
mode-`0600` JSON file with `baseUrl` and `token` fields:

```sh
cd esp32
BICINO_DEVICE_DEBUG_TOKEN='session-token' \
  python3 tools/device_debug.py --base-url http://192.168.4.1:8080 info
BICINO_DEVICE_DEBUG_TOKEN='session-token' \
  python3 tools/device_debug.py --base-url http://192.168.4.1:8080 \
  screenshot --output /tmp/bicino.png
```

Other commands are `tap X Y`, `long-press X Y --duration-ms N`,
`swipe X1 Y1 X2 Y2 --duration-ms N`, `wake`, and `exit`. The CLI validates the
device identity/dimensions before input and validates frame metadata, length,
CRC, and PNG output. It never discovers, selects, flashes, or pairs hardware.

## Evidence boundary

The captured bytes prove what the firmware intended to present after its
target-specific framebuffer rotation and physical panel write. Synthetic input
proves LVGL behavior. Neither proves that AMOLED pixels emitted light at the
same colors nor that the capacitive touch controller detected a real finger.
Keep optical and physical-touch checks in the hardware validation matrix.
