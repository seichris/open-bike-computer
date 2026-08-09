# Watch + Bicino navigation release notes

Status: draft. Do not use these notes for App Store submission until every
physical and provider-policy gate in
[`watch-bicino-navigation-validation.md`](watch-bicino-navigation-validation.md)
has passed with release-build evidence.

## What is new

- Navigate and drive the Bicino display directly from Apple Watch while the
  iPhone is off or out of range.
- Import a user-owned GPX route on iPhone, send it to Watch, and ride it offline
  after Watch reports **Ready**.
- Explicitly enable **Use Watch cellular connection** on Watch to calculate a
  cycling route to a coordinate-backed favorite and recalculate after leaving
  the route. watchOS chooses the available Wi-Fi or cellular interface.
- Continue the loaded route if Watch connectivity or recalculation fails.
- Keep workout and navigation independent: either can end while the other
  remains active.
- Automatically set up the paired Watch with a scoped ride credential when the
  iPhone is securely connected to Bicino and the Watch app is open. Bicino
  permits only one active iPhone or Watch writer at a time.

## Important behavior

- Online Watch routing is off by default and no hardware or reachability signal
  changes the setting.
- **Queued** means a route transfer is pending. Only **Ready on Watch** confirms
  exact hash-verified installation.
- Offline deviation shows distance from the route and never makes a network
  request or creates a replacement route.
- MapKit-created routes are held in active-session memory only. MapKit durable
  export and non-Apple accessory-display use remain blocked pending explicit
  approval under the current Apple terms.
- **My Bike Computers** shows the Watch-provided display name and whether
  direct rides are ready. The display name is not used as a security identity.
- Replacing or reinstalling a Watch, deregistering Bicino, or performing a
  physical ownership reset requires setup again.

## Release evidence required

- Paired iPhone/Watch route transfer and relaunch recovery.
- Offline and online rides with iPhone powered off.
- Cellular, Wi-Fi-loss, non-cellular/unsubscribed, deviation, reroute, and
  policy-toggle cases.
- Bicino reboot, exclusive-writer contention, revocation, replacement,
  downgrade, and ownership-reset cases on every supported target.
- Two-hour wrist-down battery, thermal, GPS cadence, maneuver latency, and BLE
  reconnect measurements.
- Approved provider retention, attribution, persistence, deletion, and
  accessory-display determination.
