# BikeComputer for iPhone and Apple Watch

The Xcode project is `BikeComputer/BikeComputer.xcodeproj`. Routine builds do
not require opening Xcode; use the command-line entry point below.

## Requirements

- Navigation requires iOS 16.4 or later.
- The mirrored workout experience requires iOS 17 or later and a paired Apple
  Watch running watchOS 10 or later.
- Real workout validation requires physical devices. HealthKit workout
  ownership, mirroring, route recording, disconnect behavior, and battery use
  cannot be accepted from Simulator results alone.
- The Watch must be worn and unlocked for setup and normal workout collection.
  Enable Developer Mode on both devices for Xcode installation and debugging.

## Command-line Xcode builds

Use the repository's `xcodebuild` entry point instead of opening Xcode for
routine builds:

```sh
scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The entry point works around a build-service deadlock observed with Xcode 26.6
in the verbose Apple clang discovery probe. It changes only that `/dev/null`
probe; normal compiler and linker invocations continue to use the selected
Xcode toolchain.

### Development and production apps

The standard `BikeComputer` scheme selects a distinct app family by build
configuration:

| Configuration | iPhone app | Watch app | URL scheme | Intended use |
| --- | --- | --- | --- | --- |
| Debug | `Bicino Dev` (`LetItRide.BikeComputer.dev`) | `LetItRide.BikeComputer.dev.watchkitapp` | `bikecomputer-dev` | Local development and physical-device testing |
| Release | `Bicino` (`LetItRide.BikeComputer`) | `LetItRide.BikeComputer.watchkitapp` | `bikecomputer` | TestFlight and App Store distribution |

`Bicino Dev` can coexist with the App Store app on both iPhone and Apple Watch.
It has a separate app sandbox, permissions, Keychain, background URL session,
Watch companion, complication, and Live Activity extension. TestFlight uses the
production bundle identifier, so a TestFlight build and the App Store build
replace one another rather than appearing side by side.

The bike computer currently has one owner credential. Use a dedicated test bike
computer for `Bicino Dev`, or deliberately deregister and pair it again when
switching app variants. Do not add a shared Keychain access group merely to
avoid pairing; that would let a development build read production ownership
credentials.

For a connected iPhone, replace the generic destination and unsigned setting:

```sh
scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer \
  -configuration Debug \
  -destination 'id=<iPhone UDID>' \
  -allowProvisioningUpdates \
  build
```

`-allowProvisioningUpdates` requires the WEB3 FZCO Apple Developer account to
be configured in **Xcode > Settings > Accounts**. App Store Connect API
credentials can create bundle IDs and profiles, but they do not satisfy Xcode's
automatic-signing account check. If the build reports `No Accounts`, complete
that one-time Xcode setup and rerun the same command.

Use a fresh DerivedData directory for each exact-source deployment, then treat
build, install, launch, and installed-metadata verification as separate gates:

```sh
xcrun devicectl list devices

DERIVED_DATA_PATH="$(mktemp -d /tmp/bicino-dev-derived-data.XXXXXX)"
scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer \
  -configuration Debug \
  -destination 'platform=iOS,id=IPHONE_IDENTIFIER' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  build

xcrun devicectl device install app \
  --device IPHONE_IDENTIFIER \
  "$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/BikeComputer.app"
xcrun devicectl device process launch \
  --device IPHONE_IDENTIFIER \
  --terminate-existing \
  LetItRide.BikeComputer.dev
xcrun devicectl device info apps \
  --device IPHONE_IDENTIFIER \
  --bundle-id LetItRide.BikeComputer.dev
```

The iPhone artifact embeds the Watch app, but that is not proof that the paired
Watch was updated. Wake and unlock the Watch, verify its installed app record
separately, and if necessary install the signed nested
`Watch/BikeComputerWatch.app` artifact directly to the Watch with `devicectl`.
If the Watch tunnel times out, keep the Watch near the iPhone and Mac, restore
the connection in Xcode's Devices and Simulators window, then retry the same
artifact before rebuilding.

## First run

1. Build the `BikeComputer` scheme for the paired iPhone. The Watch app is
   embedded; verify its installation on the paired Watch separately.
2. Open BikeComputer on Watch and select **Set Up Health**. Allow the requested
   workout and route permissions.
3. Allow location while using the Watch app if you want a workout route,
   elevation, and GPS fallback speed.
4. To start on Watch, return to its start screen and select **Start Ride**.
5. To start on iPhone, select **Start workout**. When a Watch is paired and the
   BikeComputer companion is installed, the iPhone starts the Watch-owned
   workout directly. Otherwise it explains the required Watch setup.

Watch and iPhone start immediately after their setup checks. Apple Watch permits
one active workout session, and public APIs do not reveal whether another app
currently owns it. If BikeComputer is displaced, it reports that outcome
instead of retrying in a loop.

## Physical-device offline-map validation

The bike computer selects offline map blocks from the WGS-84 GPS position sent
by the iPhone over BLE. An installed map covers only its requested area, so
**No map data** is expected when the current phone position is outside that
area. A completed upload, **Step 5 - 100%**, and an **Uploaded** state in the app
confirm installation; they do not mean the current GPS coordinate intersects
the installed pack.

Debug builds accept a launch-only location override. For example, this
Singapore coordinate is inside the development area used to validate 3D
buildings:

```sh
xcrun devicectl list devices
xcrun devicectl device process launch \
  --device IPHONE_IDENTIFIER \
  --terminate-existing \
  LetItRide.BikeComputer.dev \
  --device-map-location=1.305,103.855
```

The override is compiled only in `DEBUG`, is not a production location-spoofing
feature, and lasts only for that launched process. Opening the app normally
from the Home Screen launches it without the argument. Add `--console` before
the bundle identifier when diagnosing the handoff, keep that command running,
and verify these checkpoints:

```text
Developer device-map location override active: 1.305,103.855
BLE peripheral authenticated
Sent native GPS position
```

The override is applied to the next real CoreLocation update, preserving its
timestamp, accuracy, course, and speed while replacing only the coordinate.
Location permission and a BLE-authenticated bike-computer connection are still
required.

Map installation temporarily joins the Wi-Fi access point hosted by the bike
computer. If iPhone Mirroring repeatedly reports that it cannot join, approve
or retry the association on the unlocked physical iPhone before treating it as
a firmware, BLE, or transfer-server failure. This fallback was required during
physical validation even though the same join succeeded directly on the phone.

## Workout behavior

The Watch owns the `HKWorkoutSession`, `HKLiveWorkoutBuilder`, sensor collection,
route builder, final save or discard decision, and recovery record. The iPhone
is a mirrored display and control surface. It may relay the latest live snapshot
to authenticated compatible ESP32 firmware, but it never writes a second
Health workout.

Navigation and workout state are deliberately independent. Either can start or
end without implicitly changing the other.

BikeComputer heart zones use a maximum heart rate configured in iPhone
**Settings > Developer Settings > Workout Heart Zones**. The default is 190 BPM;
changes are persisted on iPhone and synced to the paired Watch.

If the iPhone or bike computer disconnects, the Watch workout continues. The
iPhone and ESP32 show delayed, disconnected, or stale state instead of treating
old data as current. Reconnection requests the newest coherent snapshot.

### Ride Detection (internal builds)

Compatible internal firmware can detect sustained cycling and coordinate the
existing Watch-owned workout. Configure **Settings > Workouts > Ride
Detection** on iPhone:

- **Ask to Start** is the default and displays **Start Ride** / **Not Now** on
  the bike computer and iPhone.
- **Start Automatically** is an explicit opt-in. It still requires a reachable,
  authorized Apple Watch running the Bicino companion; it never starts Apple's
  Workout app and does not backdate the workout.
- **Auto-Pause** requests pause after a sustained stop and resumes only a ride
  that Bicino previously auto-paused. A manual pause stays manually paused.
- **Start alerts** select sound+haptic, haptic-only, or visual-only feedback.

The Watch remains authoritative. Device/iPhone screens say **Starting**,
**Pausing**, or **Resuming** until the Watch session callback confirms the
change. A confirmed automatic transition is written to Watch recovery metadata
and a HealthKit marker while standard HealthKit pause/resume events continue to
define active duration.

**Elapsed** is wall time since confirmed start, including pauses. **Moving** is
the existing `HKLiveWorkoutBuilder.elapsedTime`, excluding confirmed pause
intervals. Both values remain local to the paired products.

Ride Detection is not advertised by production firmware until the physical
false-start, recovery, and long-run board gates pass. Standalone device ride
recording and ride history are not part of this feature.

## Importing a Strava route

When the configured Bicino service advertises Strava support, open **Settings >
Saved Routes** and choose **Import from Strava** directly below **Import GPX**.
Paste a URL in the form `https://www.strava.com/routes/123`; query parameters
and fragments are discarded. The first import opens Strava's app or web OAuth
flow. Bicino can import any cycling route that Strava makes visible to the
connected account under the granted `read` or `read_all` scope.

A successful import uses the existing validated route archive and Watch
transfer path. Its iPhone and Watch copies expire exactly seven days after the
backend fetch. Every active Strava route has a reload button, and an expired
route leaves a minimal iPhone reload row with the same button. One tap retrieves
the route again, replaces its geometry in place, preserves its Bicino-local
alias, and starts a fresh seven-day window. The rider never needs to paste the
URL again or repeat OAuth while the connection remains valid.

Expiry removes all Strava-supplied route data and the Watch copy. If the route
is being navigated on Watch at the deadline, navigation stops but an active
workout continues. Delete removes the route and reload row; **Disconnect Strava
and Delete Data** removes every Strava route, reload bookmark, and Bicino-held
connection for that app installation without modifying routes on Strava.

The integration is disabled by default and does not place a Strava client
secret or athlete token in the app. Development and Production require separate
Strava applications, exact callback URLs, backend secrets, encryption keys,
and sufficient athlete capacity. See
[`../map-platform/backend/README.md`](../map-platform/backend/README.md#strava-route-import)
and
[`../map-platform/deploy/README.md`](../map-platform/deploy/README.md#strava-route-import-configuration)
for the complete configuration and promotion contract.

## Watch + Bicino navigation without iPhone

The Watch can own location, route progress, maneuvers, and the direct
authenticated Bicino connection after setup. The iPhone is not required during
the ride. Navigation and workout are separate: ending a workout leaves active
navigation visible and running, while stopping navigation leaves an active
workout untouched.

Before the first direct ride, connect the iPhone to the Bicino, unlock Apple
Watch, and open its Bicino app. Setup then happens automatically. **My Bike
Computers** shows the Watch name and whether **Direct rides** are ready. The
Watch receives a device-local, ride-only credential; it never receives the
iPhone OwnerKey. Resetting or deregistering the Bicino invalidates that
credential. Replacing or reinstalling a Watch requires resetting or
deregistering and adding the Bicino again for now.

The iPhone also syncs its currently selected Bicino to Watch. Starting a
Watch-direct ride asks an idle iPhone app to yield that Bicino connection
automatically. The iPhone refuses while it owns active navigation, a transfer,
pairing, or device administration; in those cases Watch reports that Bicino is
busy. When the Watch-direct ride ends, the phone resumes its previous reconnect
behavior.

Offline mode is the default:

1. On iPhone, open **Settings** and find **Saved Routes**. Choose **Import GPX**
   for a durable user-owned GPX route or track, or use the optional Strava flow
   above for a seven-day provider-backed copy. The longest usable route/track
   segment is validated and saved. MapKit alternatives remain active-navigation
   only; **Save Offline** stays disabled until an approved export-capable
   provider is configured.
2. Send the route to Watch and wait for its green Watch status icon. **Queued**
   does not prove the route is installed.
3. On Watch, open **Offline Navigation**, select the installed route, and
   confirm navigation. Leaving the route shows an off-route warning; it never
   causes an online request or invents a connector route.

For online mode, explicitly enable **Use Watch cellular connection** on the
Watch. Coordinate-backed iPhone favorites then appear under **Online
Navigation** in Watch Settings. The Watch asks MapKit for a cycling route from
its current GPS position and can
recalculate after sustained deviation. This setting authorizes online routing;
it does not force a cellular interface, and watchOS may use Wi-Fi or cellular.
If connectivity or recalculation fails after a route has loaded, Bicino keeps
showing the existing route. MapKit routes created on Watch are active-session
memory only and are not written to the offline route archive.

The physical release matrix—including wrist-down location delivery, Watch BLE
reconnect, cellular and non-cellular failure behavior, two-hour battery/thermal
impact, and both supported Bicino targets—is tracked in
 [`../docs/watch-bicino-navigation-validation.md`](../docs/watch-bicino-navigation-validation.md).

## Cadence and power sensors

Pair compatible Bluetooth cycling sensors in **Apple Watch Settings >
Bluetooth > Health Devices**. Wake the sensor and start a BikeComputer cycling
workout so the Watch can collect cadence or power through HealthKit.

When BikeComputer first receives one of these measurements, the active workout
sheet offers **Connect sensor?**. Open **Settings > My Bike Computer**, or tap
that prompt, then use **My Sensors > Connect a new Sensor**. The app listens for
current workout data and lets you name a cadence sensor, power sensor, or
combined cadence-and-power sensor.

Only capabilities enabled under **My Sensors** appear as live workout tiles. An
enabled tile stays visible and shows `--` when its measurement is stale or the
sensor is not currently reporting. Forgetting or disabling the last profile
for a capability hides its tile.

Apple Watch continues to own the physical Bluetooth connection. The current
public live-workout statistics identify whether cadence or power data arrived,
but do not provide BikeComputer with a validated physical peripheral identity.
Sensor profiles are therefore local logical profiles; BikeComputer does not
claim to pair, rename, or disconnect the accessory at the system level, and it
cannot distinguish multiple accessories that report the same capability.

## iPhone Live Activity

On iOS 17 or later, a verified active Watch workout appears on the iPhone Lock
Screen and Dynamic Island while Live Activities are enabled for BikeComputer.
It shows active time, speed, distance, optional heart rate, and the most recent
completed segment. Segment and Pause/Resume use the same replay-safe Watch
control path as the in-app workout screen; End and Discard remain in the app
and on Watch.

ActivityKit permits BikeComputer to create the Live Activity only while the
iPhone app is foreground. A workout started on Watch while iPhone is
backgrounded therefore appears when BikeComputer next enters the foreground.
An existing activity continues to receive mirrored updates in the background.
Lock Screen controls require the normal iPhone authentication, and dismissing
or disabling the activity never changes the Watch workout.

Active workout metrics may be visible on the Lock Screen, Dynamic Island,
Always-On display, and other system Live Activity surfaces. No Live Activity
content is uploaded to a backend.

## Saving, discarding, and recovery

- **End and Save** creates exactly one cycling workout in Health. A route is
  attached when Watch location permission and a valid outdoor location trace
  are available.
- **Discard Workout** requires a second confirmation and saves no workout or
  route.
- The Watch persists only the minimum recovery state needed for an interrupted
  active workout: session identity, finalization state, and a derived five-zone
  time checkpoint. A relaunched Watch app asks HealthKit for the active session,
  reattaches its delegates and builder, restores cumulative time in zone, and
  reconciles an interrupted save or discard without creating a duplicate. It
  does not persist raw heart-rate samples.
- Completed Health records can be reviewed or deleted in Apple's Health or
  Fitness apps.

## Compatible bike computer firmware

Firmware with BLE capability bit 7 accepts the authenticated workout telemetry
frames and exposes Watch values on the Ride Stats pages. The ownership-capable
app can migrate a previously saved legacy peripheral and keeps its old
firmware's GPS/ride display; a fresh install does not silently trust an unknown
shared-key device. Ownership-v2 firmware rejects the old app-wide key, so
release and install the compatible app before that firmware.

The full wire contract is in [`../docs/ble-protocol.md`](../docs/ble-protocol.md).
The remaining release acceptance checklist is tracked in
[GitHub issue #117](https://github.com/seichris/open-bike-computer/issues/117).

## Privacy

Health and workout-route values stay within HealthKit and the rider's paired
Watch, iPhone, and authenticated local bike computer connection. They are not
sent to the Bike Computer backend. The ESP32 keeps workout metrics in RAM only.
See [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) and
[`../docs/app-store-privacy-disclosures.md`](../docs/app-store-privacy-disclosures.md).
