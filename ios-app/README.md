# BikeComputer for iPhone and Apple Watch

Open `BikeComputer/BikeComputer.xcodeproj` in Xcode.

## Requirements

- Navigation requires iOS 16.4 or later.
- The mirrored workout experience requires iOS 17 or later and a paired Apple
  Watch running watchOS 10 or later.
- Real workout validation requires physical devices. HealthKit workout
  ownership, mirroring, route recording, disconnect behavior, and battery use
  cannot be accepted from Simulator results alone.
- The Watch must be worn and unlocked for setup and normal workout collection.
  Enable Developer Mode on both devices for Xcode installation and debugging.

## First run

1. Build the `BikeComputer` scheme for the paired iPhone. The Watch app is
   embedded and installs to the paired Watch.
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
See [`../PRIVACY_POLICY.md`](../PRIVACY_POLICY.md) and
[`../docs/app-store-privacy-disclosures.md`](../docs/app-store-privacy-disclosures.md).
