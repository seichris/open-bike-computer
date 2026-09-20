# Watch workout companion release notes

Release candidate: **1.8 (18)**. App Store version 1.7 is already distributed,
and App Store Connect already contains builds through 17, so both the marketing
version and build number advance for this release.

## App Store What's New

Find destinations and navigate more reliably on your Bicino.

- Keep destination search visible while using the keyboard.
- Open shared map links more reliably from Safari.
- Receive more consistent navigation updates over Bluetooth.
- Use the right button to move backward through bike computer screens.

## App Review notes

Bicino includes a companion Apple Watch app. The Watch is the sole owner
and writer of outdoor cycling workouts. The iPhone uses Apple's workout-session
mirroring APIs for display and remote controls and never saves a duplicate
workout.

To test:

1. Install the iPhone build and its embedded Watch app on a paired Watch.
2. Open Bicino on Watch, select **Set Up Health**, and grant workout and
   location access.
3. Select **Start Ride**.
4. Open Bicino on iPhone to view the same live workout and use mirrored
   pause, resume, save, discard, or segment controls. Lock the iPhone to review
   the Live Activity and authenticate a Segment or Pause/Resume action.
5. End that workout, then select **Start workout** on iPhone. With the Watch
   paired and the companion installed, this starts the Watch-owned workout
   directly without a second confirmation.

The privacy policy is available from **Settings > Privacy Policy** on iPhone and
from **Settings > Privacy Policy** on Apple Watch.

Watch and iPhone starts proceed directly after their setup checks. Public APIs
cannot detect another app's workout, so any resulting displacement is reported
honestly instead of being retried. Saving creates one Health workout from Watch;
discarding creates none. A route requires Watch location permission
and actual outdoor movement.

The Live Activity is created after a verified Watch snapshot while the iPhone
app is foreground. If a ride starts from Watch while iPhone is backgrounded,
foreground Bicino once to create it. Active workout metrics may remain
visible on the Lock Screen and Always-On display. Dismissing or disabling the
Live Activity has no effect on the Watch-owned workout, and no Live Activity
content is sent to a backend.

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
- New app + new firmware: the app uses the dedicated workout characteristic.
  Current firmware supports acknowledged native writes. For earlier firmware
  with an unacknowledged workout characteristic, the app prefers acknowledged
  `WTLM` and retains native no-response delivery only when no acknowledged route
  exists. Persistent no-response backpressure causes a bounded reconnect.

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
