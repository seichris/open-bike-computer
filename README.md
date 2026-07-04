<img width="2375" height="871" alt="bike_header" src="https://github.com/user-attachments/assets/06dda2a2-b5b1-4a5c-86de-9ac191c8e657" />

# Open Source Bike Computer

Navigate your bike rides with a ~$30 open source bike computer.

- **Paired iOS app**: Plan routes, record workout metrics, and stream turn-by-turn navigation, GPS, map settings, and ride telemetry to the handlebar display over BLE.
- **Supported hardware**:
  - [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262)
  - [Waveshare ESP32-S3-Touch-AMOLED-2.06](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm)
  - [Seeed Studio XIAO nRF52840](https://www.seeedstudio.com/Seeed-XIAO-BLE-nRF52840-p-5201.html) + [1.28" Round Touch Display for XIAO](https://www.seeedstudio.com/1-28-Round-Touch-Display-for-Seeed-Studio-XIAO-ESP32.html) via [PR #31](https://github.com/seichris/open-bike-computer/pull/31)

The firmware, iOS app, and hardware notes are open source, so you can tailor the
device to your rides. See [CONTRIBUTING.md](CONTRIBUTING.md) to build on this
codebase.

The iOS app needs an internet connection for route planning. For a fully
offline, phone-free setup, flash [IceNav-v3](https://github.com/jgauchia/IceNav-v3)
on a GPS-equipped board like the
[Waveshare ESP32-S3-Touch-AMOLED-1.75 with GPS](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31264).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the repo layout, build and test flow, supported-hardware notes, and the current BLE protocol overview.

## Offline maps

See [OFFLINE_MAPS.md](OFFLINE_MAPS.md) to generate OpenStreetMap vector blocks
for SD-card map rendering.
