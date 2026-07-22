<img width="2375" height="871" alt="bike_header" src="https://github.com/user-attachments/assets/06dda2a2-b5b1-4a5c-86de-9ac191c8e657" />

Navigate and record bike rides with a sleek, Garmin-mounted bike computer,
iPhone, and optional Apple Watch companion.

## Get started

1. **Get your bike computer.** Choose the round [Waveshare 1.75-inch](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262), the larger rectangular [Waveshare 2.06-inch](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm), or a compact round build using the [Seeed Studio XIAO nRF52840](https://www.seeedstudio.com/Seeed-XIAO-BLE-nRF52840-p-5201.html) + [1.28-inch Round Touch Display](https://www.seeedstudio.com/1-28-Round-Touch-Display-for-Seeed-Studio-XIAO-ESP32.html).
2. **Download the free iOS app** and pair your bike computer.
3. **Optional: pair an Apple Watch.** On iOS 17 and watchOS 10 or later, the
   Watch app can own and record an outdoor cycling workout, mirror live metrics
   to iPhone, and relay supported metrics to compatible ESP32 firmware.
4. **Ride.** Navigation and the Watch workout are independent: use either one
   by itself, or run both together for turn-by-turn guidance and live ride
   statistics on the handlebars.

## Apple Watch workouts

- The Apple Watch is the workout owner and the only component that saves an
  `HKWorkout`.
- A workout can be started directly from either Watch or iPhone after its setup
  checks. The iPhone verifies that a Watch is paired and the BikeComputer
  companion is installed. The Watch must be worn, unlocked, paired, and
  authorized for Health access. Watch location access is optional; without it,
  route, elevation, and GPS fallback metrics remain unavailable.
- Live heart rate, elapsed time, distance, speed, active energy, and available
  power and cadence values appear on Watch and iPhone. The iPhone also shows
  available altitude. Firmware advertising workout telemetry capability shows
  supported current values on the ESP32 Ride Stats pages. BikeComputer also
  calculates five live heart-rate zones from the maximum heart rate configured
  in iPhone Developer Settings: below 60%, 60–70%, 70–80%, 80–90%, and 90% or
  more. These are BikeComputer zones, not Apple's personalized system workout
  zones.
- Missing sensors stay visibly unavailable; they are not displayed as zero.
- Saving creates one Health workout. Discarding creates none. Ending navigation
  does not end the workout, and ending the workout does not stop navigation.

See [the iOS and watchOS guide](ios-app/README.md) for setup, compatibility,
privacy, recovery, and real-device validation requirements.

## Contributing

Ideas and feature requests are welcome—[open an issue](https://github.com/seichris/open-bike-computer/issues/new).

For code contributions, see
[CONTRIBUTING.md](https://github.com/seichris/open-bike-computer/blob/main/CONTRIBUTING.md).

## License

Open Bike Computer uses an open source component model:

- the network map backend and its configuration are AGPL-3.0-only;
- the iOS app and other project-authored distributed or local software are
  GPL-3.0-only; and
- imported GPL components such as the ESP32 firmware base and map extraction
  tools retain their existing license terms.

Contributors retain copyright and contribute under the
[Contributor License Agreement](CLA.md). The agreement keeps contributions
available under the applicable public license while allowing the repository
owner to offer separately licensed official builds, including App Store builds.

See [LICENSES.md](LICENSES.md) for the exact path-by-path licensing boundaries.
