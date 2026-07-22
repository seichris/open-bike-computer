# Watch workout companion release notes

Release candidate: **1.1 (7)**. App Store version 1.0 is already distributed,
and App Store Connect already contains builds through 5, so both the marketing
version and build number must advance for this release.

## App Store What's New

Record rides from Apple Watch and keep the important numbers visible across
Watch, iPhone, and compatible Bike Computer hardware.

- Start an outdoor cycling workout from Watch or iPhone.
- See live heart rate, time, distance, speed, energy, and available cycling
  sensor data.
- Pause, resume, save, or discard from either Apple device.
- Recover an active Watch workout after an interruption.
- Keep navigation and workout controls independent.
- Show current Watch metrics on the ESP32 Ride Stats pages with compatible
  firmware.

The workout companion requires iOS 17 and watchOS 10 or later. Existing iPhone
navigation remains compatible with iOS 15 and later.

## App Review notes

BikeComputer includes a companion Apple Watch app. The Watch is the sole owner
and writer of outdoor cycling workouts. The iPhone uses Apple's workout-session
mirroring APIs for display and remote controls and never saves a duplicate
workout.

To test:

1. Install the iPhone build and its embedded Watch app on a paired Watch.
2. Open BikeComputer on Watch, select **Set Up Health**, and grant workout and
   location access.
3. Select **Start Ride**.
4. Open BikeComputer on iPhone to view the same live workout and use mirrored
   pause, resume, save, or discard controls.
5. End that workout, then select **Start workout** on iPhone. With the Watch
   paired and the companion installed, this starts the Watch-owned workout
   directly without a second confirmation.

The privacy policy is available from **Settings > Privacy Policy** on iPhone and
from **Privacy Policy** on the Watch start screen.

Watch and iPhone starts proceed directly after their setup checks. Public APIs
cannot detect another app's workout, so any resulting displacement is reported
honestly instead of being retried. Saving creates one Health workout from Watch;
discarding creates none. A route requires Watch location permission
and actual outdoor movement.

No account or external cycling sensor is required. Optional Bluetooth bike
computer hardware is not required to review the Watch/iPhone workflow.

## Firmware rollout notes

Release this ownership-capable app version before ownership-v2 firmware with
BLE capability bit 7.

- New app + previously saved old firmware: the app can use its explicit legacy
  migration path; navigation and legacy ride telemetry continue, while Watch
  workout values are not sent to the device.
- Fresh new-app install + unknown old firmware: the app does not silently trust
  the shared app-wide key; update the device through an already registered
  installation or install ownership-v2 firmware through the supported flow.
- Old app + ownership-v2 firmware: authentication is intentionally rejected;
  update the app before installing the firmware.
- New app + new firmware: authenticated native workout characteristics are
  preferred, with the documented 20-byte plaintext `WTLM` fallback (42 bytes
  after ownership-v2 wire protection) where required.

Do not advertise capability bit 7 in any firmware release that lacks the frame
parser, RAM-only workout state, staleness handling, and Ride Stats UI.

## Release gate

This copy is prepared metadata, not authorization to publish. Before release,
complete every pending item in
[GitHub issue #117](https://github.com/seichris/open-bike-computer/issues/117),
export and visually approve the updated screenshots, verify the final App Store
privacy answers and public policy against production, verify the in-app and App
Store Connect privacy links resolve to the same policy, and release the app and
firmware in the order above.
