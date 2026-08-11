# Pre-Connection Screen Redesign Implementation Plan

## Outcome

Replace the ESP32 waiting screen's technical `ADD`, `PAIR`, `BLE`, `AUTH`, and
`LINK` badges with a branded, plain-language Bicino setup and connection flow.
The 466 x 466 round Waveshare AMOLED is the primary visual target. The battery
remains centered at the narrow top of the circle, while branding, pairing, and
connection content use the wider middle of the display.

The finished flow is:

```text
Welcome
  -> Confirm this code
  -> Confirmed here
  -> Connecting...
  -> iPhone connected / Getting your location...
  -> existing Map or Map + Navigation UI
```

An already registered device that is not connected shows `Waiting for iPhone`
between Welcome/pairing and Connecting.

This work also changes the shared route/current-position color from cyan
`#18F3FF` to Bicino navigation blue `#0088FF`. The same blue is used for the
GPS dot, current-position heading arrow, route line, and pre-connection
connection-progress artwork.

The implementation does not add a connection status bar, badge, icon, or
other overlay to Map, Map + Navigation, workout, or ride-stat screens.

## Baseline

This plan was prepared from freshly fetched `origin/main` at
`344e8b6831cc4ffd3619d3daf74cef1c67b7fc7c`.

The current implementation has these relevant properties:

- `waitingScr.cpp` builds one generic LVGL layout containing the battery,
  dynamic device-name title, outlined state badge, and message.
- `updateWaitingOwnershipStatus()` derives the badge and copy from
  `claimed`, `connected`, `authenticated`, and an optional pairing code.
- `ble_navigation.cpp` copies ownership/BLE state under a critical section and
  applies UI changes later on the LVGL task.
- The secure-pairing comparison is not confirmable until the code has reached
  the physical display. `ownershipComparisonRenderGate`, the display-flush
  callback, and the BOOT/PWR input gates enforce that security property.
- A physical button confirmation currently leaves the same pairing-code
  presentation on screen because the UI snapshot does not expose
  `pairingConfirmedOnDevice_`.
- Authentication does not itself reveal the map. The first accepted GPS packet
  or route geometry sets `pendingTransitionToMap`; the main loop then calls
  `loadMainScreen()`.
- The current route, position dot, and position arrow already share
  `navigation_visual_style::ROUTE_BLUE_*`, currently `#18F3FF` / `0x1F9F`.
- The round target is 466 x 466. The supported 2.06-inch target is 410 x 502.
- `waitingScreenLayout.hpp` is already a pure, host-testable layout helper.
- `test_gui_layout.cpp` compiles for both display sizes in CI.
- LVGL's runtime QR widget is disabled with `LV_USE_QRCODE 0`.

No BLE UUID, command, cryptographic transcript, iOS pairing protocol, map-entry
trigger, or post-entry disconnect behavior needs to change.

## Product contract

### Screen sequence and copy

| Presentation phase | Hero content | Headline | Supporting copy | Accent |
| --- | --- | --- | --- | --- |
| Welcome | App Store QR code | `Welcome` | `Download the Bicino app`<br>`and add your new device!` | Bicino red for the logo |
| Pairing comparison | Large grouped code such as `123 456` | `Confirm this code` | `If it matches your iPhone,`<br>`press either device button.` | Amber |
| Confirmed on device | Check inside a circle | `Confirmed here` | `Tap Codes Match`<br>`on your iPhone.` | Green |
| Registered and disconnected | iPhone with radio/link marks | `Waiting for iPhone` | `Open Bicino on your iPhone.` | Neutral gray with blue detail |
| Connected, authenticating | iPhone and lock/link artwork | `Connecting...` | `Creating a secure connection.` | Blue |
| Authenticated, awaiting initial map input | Connected check plus location dot | `iPhone connected` | `Getting your location...` | Green confirmation plus blue location detail |

The actual firmware strings use three ASCII periods rather than a Unicode
ellipsis unless the selected font asset is explicitly extended and tested.

There are deliberately no dedicated presentations for:

- location delayed;
- first map render;
- connection failed; or
- disconnection after the map/workout UI is already visible.

Normal cancellation, timeout, and disconnect events resolve to the appropriate
Welcome, Waiting, or Connecting presentation from current state; they do not
create new error screens.

### Brand treatment

- Display the canonical Bicino mark in brand red `#FF372E` with `Bicino` in
  white beside it.
- Welcome uses the full lockup. Other pre-connection phases use the same lockup
  at a smaller size so the screen remains recognizably Bicino without restoring
  a technical state badge.
- Remove the `ADD` badge completely. Do not substitute a plus icon, Bluetooth
  wordmark, or another setup badge on Welcome.
- Do not use the configurable device name as the main pre-connection headline.
  Device naming remains available in the iPhone app and BLE ownership record.
- Keep the background pure black for AMOLED contrast and power behavior.

### Color contract

Create one shared firmware token for Bicino navigation blue:

```cpp
constexpr uint32_t NAVIGATION_BLUE_RGB888 = 0x0088FF;
constexpr uint16_t NAVIGATION_BLUE_RGB565 = 0x045F;
```

`#0088FF` matches Apple's current default system blue and the solid center of
the MapKit location dot in the repository's checked-in iOS capture. Apple
describes user location as a pulsing blue dot but does not publish a separate
GPS-dot hex token:

- [Apple Human Interface Guidelines: Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [MapKit: Showing the user's location](https://developer.apple.com/documentation/mapkitjs/map/showsuserlocation)

Use the shared token for:

- route geometry in the RGB565 map surface;
- the circular current-position marker;
- the directional current-position arrow;
- blue connection/link/location artwork on the pre-connection screen.

Keep the existing semantic colors separate:

| Purpose | RGB888 |
| --- | --- |
| Bicino brand mark | `#FF372E` |
| Success/confirmed | `#35D46F` |
| Pairing attention | `#F6B73C` |
| Inactive/registered waiting | `#8B93A1` |
| Secondary text | `#AAAAAA` |
| Background | `#000000` |

Do not recolor unrelated battery, warning, workout, or settings visuals as part
of this change.

## State model

### Pure presentation resolver

Introduce a small Arduino/LVGL-independent model, for example
`preConnectionPresentation.hpp`:

```cpp
struct Snapshot {
  bool claimed;
  bool connected;
  bool authenticated;
  bool pairingActive;
  bool pairingConfirmedOnDevice;
  uint32_t pairingCode;
};

enum class Phase : uint8_t {
  Welcome,
  PairingComparison,
  PairingConfirmed,
  WaitingForIPhone,
  Connecting,
  GettingLocation,
};
```

Resolve phases in this exact priority order:

1. Connected plus active pairing plus device confirmation ->
   `PairingConfirmed`.
2. Connected plus active pairing without device confirmation ->
   `PairingComparison`.
3. Connected plus authenticated session -> `GettingLocation`.
4. Connected but unauthenticated -> `Connecting`.
5. Claimed but disconnected -> `WaitingForIPhone`.
6. Otherwise -> `Welcome`.

This priority prevents a connected or claimed flag from hiding an active
pairing comparison. It also lets a newly paired-but-not-yet-authenticated
session move naturally from PairingConfirmed to Connecting.

Format pairing codes as two zero-padded groups:

```text
000 042
123 456
```

The formatter must preserve all six digits, including leading zeroes.

### BLE-to-UI snapshot

Refactor the queued ownership UI state so it carries the complete presentation
snapshot rather than treating `pairingCode >= 0` as the entire pairing state.

Requirements:

- Read pairing-active, pairing-confirmed, code, and generation while holding
  `deviceOwnershipMutex`.
- Copy the snapshot under the existing ownership UI critical section.
- Continue applying all LVGL mutations only from
  `applyPendingOwnershipUiUpdate()` on the UI task.
- Request/arm the comparison render gate only for an active, unconfirmed
  pairing generation.
- Cancel the comparison render request after device confirmation, pairing
  completion, cancellation, timeout, or disconnect.
- Preserve the rule that only an input generated after the comparison was
  physically rendered can confirm ownership.
- Keep the existing `PAIR_READY`, `CONFIRM`, and `PAIRED` protocol messages
  unchanged.

Expose the smallest read-only ownership accessor or snapshot needed to convey
`pairingConfirmedOnDevice_`; do not make pairing internals mutable from the UI.

## Round-screen visual architecture

### Persistent LVGL object tree

Build the waiting screen once and update object visibility/content when the
phase changes. Do not destroy and recreate the screen for every BLE event.

Use these groups:

- common: battery;
- identity: full Welcome lockup or compact non-Welcome lockup;
- welcome: headline, QR image, download copy;
- pairing: headline, code, instructions;
- status: static hero artwork, headline, supporting copy.

Only the active group is visible. Cache the displayed phase, code, battery
text, and colors so identical updates do not invalidate the full screen.

Keep all hero artwork static. A spinner, pulsing ring, or looping startup
animation would cause continuous full-screen AMOLED flushes. A future one-shot
brand animation can be designed separately after its frame cost is measured.

### 466 x 466 primary layout

Use the circle's geometry rather than treating the display as a square canvas.
The initial layout targets are:

| Element | Initial placement |
| --- | --- |
| Battery | centered, `y = 28...62`, Montserrat 24 |
| Full Welcome wordmark | centered, `y = 76...114` |
| Welcome headline | centered, `y = 122...168`, Montserrat 38 or 42 |
| QR image | 165 x 165, centered horizontally, `y = 174...339` |
| Welcome copy | centered, `y = 356...420`, Montserrat 18 |
| Pairing headline | centered near `y = 126` |
| Pairing code | centered in the widest area near `y = 190`, Montserrat 48 with tabular-looking spacing |
| Pairing instructions | centered below the code, no lower than the round-safe bottom chord |
| Status hero | centered in the wide middle, approximately 96...112 px |
| Status headline/copy | below the hero and above the narrowing bottom edge |

Treat these as code-level starting coordinates, then make the smallest changes
needed from a 1:1 reference image and physical-panel review.

Extend `waitingScreenLayout.hpp` with state-specific layouts and a constexpr
round-safe check. For the 466 x 466 profile, opaque corners of every wordmark,
QR, code, icon, and text box must remain inside the circle with a visual inset.
Transparent label bounds may be wider, but rendered glyphs may not clip.

### 410 x 502 secondary layout

Retain the same state names, copy, assets, and hierarchy on the 2.06-inch
target, with a separate rectangular placement profile. It need not imitate the
round screen's empty corners. It must compile, fit, and remain readable without
changing the round-first product decisions.

## Asset contract

### Bicino logo

Use the canonical logo mask from the Bicino website repository:

```text
bicino/public/images/bicino-logo.png
```

At planning time its `origin/main` source commit is
`a7b0bc0cdbf4e01b8afee9d614c8c8ffab884a9e`, and the website applies brand red
`#FF372E` to the mask. Record the source repository, commit, blob hash, output
dimensions, color, and generated-data checksum beside the firmware asset.

Generate a small LVGL-compatible flash asset; do not load the website PNG from
the SD card at runtime. Render `Bicino` as an LVGL label so the lockup can adapt
between display profiles without maintaining multiple raster wordmarks.

### App Store QR code

Before freezing the QR asset, add and deploy a stable Bicino-owned URL:

```text
https://bicino.com/app
```

That endpoint should redirect to the current App Store listing for app ID
`6788977349`. The owned URL keeps already-shipped firmware valid if Apple's
regional or marketing URL changes. This web redirect is a separate Bicino
website change and is a prerequisite for the final firmware asset.

Generate the QR with these rules:

- payload exactly `https://bicino.com/app`;
- error correction M;
- black modules on an opaque white background;
- four-module white quiet zone;
- no logo, color, rounded modules, or decorative frame inside the code;
- integer pixel scaling only; and
- no LVGL zoom or interpolation.

For the short payload, the expected Version 2 matrix is 25 x 25 modules. With
the quiet zone it becomes 33 x 33 modules; five pixels per module produces a
165 x 165 image suitable for the round display. The generator must fail rather
than silently change dimensions if the encoded matrix version changes.

Store the final QR as a pre-generated, palette-backed LVGL I1 image in flash.
This keeps `LV_USE_QRCODE` disabled, avoids runtime QR allocation, and reduces
the asset to a few kilobytes. Verify the I1 palette and bit order on the real
RGB565 display before accepting it.

Add a deterministic developer tool that:

1. validates the exact URL and QR parameters;
2. generates the logo and QR LVGL descriptors;
3. writes a manifest containing inputs and SHA-256 outputs; and
4. supports a check mode so CI can detect stale generated data.

Pin any Pillow/QR-generation dependency used by that tool. Generation is a
development/CI operation, never part of device boot.

## Static connection artwork

Draw simple check, phone, radio/link, lock, and location forms with a small set
of LVGL primitives. Keep their construction in a dedicated helper rather than
embedding dozens of style calls in `waitingScr.cpp`.

Requirements:

- no icon appears on Welcome besides the Bicino mark and QR code;
- no replacement `ADD` icon exists;
- icon strokes remain at least 4 physical pixels on the 466 panel;
- blue components use the shared `#0088FF` token;
- the confirmed check uses success green;
- the GettingLocation artwork may combine a green connection check with a blue
  GPS dot, but it must remain one static composition; and
- icons are hidden as soon as the existing map screen is loaded.

## Implementation phases

### Phase 0: external URL and visual reference gate

1. Add `https://bicino.com/app` in the Bicino website and point it to App Store
   app ID `6788977349`.
2. Verify the redirect from an iPhone and from a clean HTTP request.
3. Produce 1:1 466 x 466 references for all six phases and a 410 x 502 fit
   reference using the exact strings, fonts, asset dimensions, and colors.
4. Review the round-screen references before generating firmware assets.

The final QR must not encode an unverified or temporary URL.

### Phase 1: shared visual tokens and assets

1. Add a small header-only Bicino visual-style module with RGB888/RGB565
   conversion and semantic color tokens.
2. Change route, position dot, and position arrow consumers to the shared
   navigation blue and lock its RGB565 conversion with a static assertion.
3. Add the deterministic pre-connection asset generator and manifest.
4. Generate the Bicino mark and 165 x 165 I1 QR descriptors.
5. Add a host asset check for dimensions, payload manifest, palette, quiet
   zone, and generated checksums.

### Phase 2: presentation state and pairing confirmation

1. Add the pure `Snapshot -> Phase` resolver and pairing-code formatter.
2. Extend the device-ownership read-only surface with device-confirmed pairing
   state.
3. Refactor the BLE-to-UI queued snapshot to carry all resolver inputs.
4. Update the render-gate decision so only the unconfirmed comparison phase
   arms physical confirmation.
5. Preserve all current mutex, critical-section, UI-task, and fresh-button-edge
   boundaries.

### Phase 3: round-first waiting screen

1. Replace the generic title/state/message layout with common, welcome,
   pairing, and status object groups.
2. Keep the existing battery read, charging symbol, 30-second update timer, and
   screen-load/screen-unload timer pausing.
3. Add the full and compact Bicino lockups.
4. Add the Welcome QR and copy with no `ADD` artwork.
5. Add pairing comparison and device-confirmed presentations.
6. Add Waiting, Connecting, and GettingLocation static artwork and copy.
7. Apply only changed properties when a snapshot changes.
8. Leave the existing GPS/route-driven `pendingTransitionToMap` path intact.

### Phase 4: automated and physical validation

1. Run host state, layout, ownership, color, and asset tests.
2. Build both production Waveshare targets and existing CI variants.
3. After asking which physical device is connected, flash the matching target
   and execute the physical matrix below.
4. Record 1:1 photographs/screenshots, QR scan evidence, firmware size delta,
   heap/PSRAM observations, and the exact tested commit in the pull request.

## Expected file changes

| File or area | Planned change |
| --- | --- |
| `esp32/lib/bicino_style/bicino_visual_style.hpp` | New shared semantic RGB888/RGB565 tokens |
| `esp32/lib/route_overlay/navigation_visual_style.hpp` | Retain navigation sizing and consume/alias the shared blue token |
| `esp32/lib/route_overlay/route_overlay.cpp` | Use the shared RGB565 navigation blue |
| `esp32/lib/maps/src/maps.cpp` | Use the shared RGB888/RGB565 blue for dot, arrow, and route-related drawing |
| `esp32/lib/gui/src/preConnectionPresentation.hpp` | New pure snapshot, phase resolver, and code formatter |
| `esp32/lib/gui/src/preConnectionIcons.*` | New static LVGL connection artwork helper |
| `esp32/lib/gui/src/waitingScreenLayout.hpp` | State-specific round and rectangular layouts plus fit checks |
| `esp32/lib/gui/src/waitingScr.cpp/.hpp` | New object groups and phase-driven presentation |
| `esp32/lib/ble_navigation/device_ownership.hpp` | Minimal read-only pairing-confirmed accessor/snapshot |
| `esp32/lib/ble_navigation/ble_navigation.cpp` | Complete queued UI snapshot and render-gate handling |
| `esp32/lib/images/src/bicino_logo.*` | Generated flash-resident Bicino logo asset |
| `esp32/lib/images/src/bicino_app_qr.*` | Generated 165 x 165 I1 QR asset |
| `esp32/tools/generate_preconnection_assets.py` | Deterministic asset generation/check tool |
| `esp32/tools/preconnection-assets.*` | Pinned tool dependencies and generated-input manifest |
| `esp32/tools/tests/test_pre_connection_presentation.cpp` | Resolver and code-format tests |
| `esp32/tools/tests/test_gui_layout.cpp` | Round-safe and 2.06 layout assertions |
| `esp32/tools/tests/test_device_ownership.cpp` | Pairing-confirmed state lifecycle assertions |
| `.github/workflows/ci.yml` | Run new host and generated-asset checks |

The implementation should not require edits to iOS pairing UI: it already
shows the matching code and exposes the button label `Codes Match` after
`PAIR_READY` is received.

## Automated verification

### Presentation resolver matrix

Host tests must cover at least:

| Claimed | Connected | Authenticated | Pairing active | Confirmed on device | Expected phase |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0 | 0 | 0 | 0 | 0 | Welcome |
| 0 | 1 | 0 | 0 | 0 | Connecting |
| 0 | 1 | 0 | 1 | 0 | PairingComparison |
| 0 | 1 | 0 | 1 | 1 | PairingConfirmed |
| 1 | 0 | 0 | 0 | 0 | WaitingForIPhone |
| 1 | 1 | 0 | 0 | 0 | Connecting |
| 1 | 1 | 1 | 0 | 0 | GettingLocation |
| 1 | 1 | 1 | 1 | 0 | PairingComparison, because pairing has priority |
| 1 | 0 | 1 | 0 | 0 | WaitingForIPhone; disconnected state wins over a stale authenticated flag |
| 0 | 0 | 0 | 1 | 0 | Welcome; pairing is never presented without a live connection |

Also test pairing codes `000000`, `000042`, `123456`, and `999999`.

### Layout and asset tests

- Every visible rectangle fits its 466 x 466 or 410 x 502 display profile.
- All opaque 1.75-inch content passes the round-safe inset check.
- Welcome uses a 165 x 165 QR rectangle with no scaling.
- The QR descriptor is I1, has exactly two opaque palette colors, retains the
  four-module quiet zone, and matches its manifest checksum.
- The QR matrix decodes to exactly `https://bicino.com/app` in a generator test.
- The logo output matches its pinned source blob and brand color.
- `NAVIGATION_BLUE_RGB565` remains `0x045F`.
- No technical badge strings `ADD`, `PAIR`, `AUTH`, or `LINK` remain in the
  waiting-screen presentation.

### Ownership/security regression tests

- A button press before the comparison frame flush cannot confirm pairing.
- A fresh BOOT press after the frame flush confirms once.
- A fresh PWR press after the frame flush confirms once.
- The UI phase changes from PairingComparison to PairingConfirmed after the
  accepted physical input.
- Confirmed pairing cannot be armed or confirmed a second time.
- Timeout, cancellation, disconnect, persistence failure, and successful
  `PAIRED` handling clear the confirmed/pairing presentation correctly.
- Existing ownership cryptographic fixtures and iOS protocol tests remain
  unchanged and green.

### Build commands

At implementation time, run the new checks with warnings as errors and the
repository's complete existing host suite. The minimum production builds are:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

CI must also retain the speaker-honk and display-test variants in the
repository's separate firmware-diagnostics workflow.

## Physical validation matrix

Before the first build/upload/serial/device action, ask which physical board is
connected and select the matching PlatformIO environment.

On the 1.75-inch round device:

1. Clear ownership through the existing supported recovery flow and boot to
   Welcome.
2. Verify the battery is centered in the narrow top chord and no visible
   content clips at any round edge.
3. Verify the Bicino logo is red, the wordmark is white, and no `ADD` icon or
   badge appears.
4. Scan the QR at normal and reduced display brightness with the iPhone Camera
   app; confirm it opens the correct App Store product through
   `bicino.com/app`.
5. Start Add Device and verify the same six-digit code appears on device and
   iPhone, including a leading-zero fixture if practical.
6. Confirm once with BOOT and in a separate run once with PWR. Verify both move
   immediately to Confirmed here and neither leaks its normal non-pairing
   action.
7. Tap `Codes Match` on iPhone and observe Connecting, then iPhone connected /
   Getting your location.
8. Send the first accepted GPS packet and separately test route-first geometry;
   each must transition directly to the existing map UI.
9. Disconnect before initial GPS and verify the registered device resolves to
   Waiting for iPhone without a new failure screen.
10. Reconnect and authenticate again, verifying the same Connecting and
    GettingLocation progression.
11. Once Map, Map + Navigation, workout, and ride-stat screens are visible,
    disconnect/reconnect and verify no new status bar, badge, or icon overlays
    them.
12. Load a route and inspect the route, GPS dot, and heading arrow in bright
    indoor and outdoor lighting; all three must use the same blue and remain
    distinguishable from map features.
13. Verify unknown battery, low battery, and charging copy do not disturb the
    round layout.
14. Leave every static phase idle long enough to verify there is no continuous
    redraw, animation, watchdog, or memory growth.

For the 2.06-inch target, require both a production build and a screen-fit
smoke test when hardware is available. The 1.75-inch physical review remains
the release-defining visual gate for this round-first design.

## Performance and size gates

- No looping animation or periodic connection spinner is introduced.
- Identical ownership snapshots cause no LVGL property changes.
- The existing waiting-screen battery timer remains the only periodic UI
  update while state is unchanged.
- QR and logo data live in flash; creating Welcome does not allocate a runtime
  QR encoder or a 165 x 165 canvas.
- Record firmware binary/flash delta for both targets.
- Record free heap, largest free heap block, free PSRAM, and largest free PSRAM
  block before and after creating the waiting screen.
- Repeated pairing/connect/disconnect cycles must not show unbounded memory
  loss or growing LVGL object count.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| App Store marketing URL changes after devices ship | Encode the stable Bicino-owned redirect, not Apple's regional URL |
| QR becomes blurry or hard to scan | Version-lock the matrix, preserve four quiet modules, use 5 px per module, and disable image scaling |
| I1 palette or bit order renders incorrectly on RGB565 | Add descriptor tests and require physical scan evidence |
| Round display clips lower copy | Use state-specific layouts, round-safe host checks, and 1:1 physical review |
| New UI state weakens physical pairing confirmation | Keep the display-flush generation gate and fresh-button-edge policies authoritative |
| BLE callback mutates LVGL | Preserve the queued snapshot and UI-task-only application boundary |
| Blue values drift between route and connection UI | Keep one shared RGB888/RGB565 semantic token with static assertions |
| Static icon helper grows into a second design system | Limit it to the five pre-connection compositions in this plan |
| 2.06 layout regresses | Maintain a separate fit profile and build both production targets |

## Out of scope

- A status bar or connection indicator on Map, Map + Navigation, workout, or
  ride-stat screens.
- Location-delayed, first-map-render, or connection-failed presentations.
- Changing the data-driven GPS/route map-entry trigger.
- Changing what an already visible map does after disconnect.
- BLE UUID, payload, cryptography, or iOS pairing-flow changes.
- Deep-linking directly into a particular Add Device screen after App Store
  installation.
- A startup animation, spinner, pulsing connection art, or other continuous
  animation.
- Rebranding unrelated settings, battery, workout, or diagnostics screens.
- Changing route width, marker size, map profile defaults, or map rendering
  architecture.

## Definition of done

The implementation is complete only when:

- Welcome shows the Bicino mark, Bicino wordmark, Welcome headline, scannable
  App Store QR, requested download/add-device copy, and no `ADD` badge;
- all six pre-connection phases resolve from real ownership/BLE state with the
  exact approved copy;
- a physical button confirmation has its own Confirmed here presentation while
  preserving the current pairing security gate;
- the battery remains correctly placed for the round display;
- route, current-position dot, current-position arrow, and connection-progress
  artwork share `#0088FF` / `0x045F`;
- map and workout screens gain no status overlay or connection icon;
- no delayed-location, first-render, or connection-failure screen exists;
- host state/layout/asset/ownership tests pass;
- both production firmware targets and existing CI variants build;
- the full 1.75-inch physical matrix passes with QR scan and visual evidence;
- firmware size and runtime memory deltas are recorded and bounded; and
- the pull request names the exact firmware commit, Bicino logo source commit,
  QR redirect deployment, commands run, and physical device used.
