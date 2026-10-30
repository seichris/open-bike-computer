# Early startup logo: Waveshare 1.75-inch

The 1.75-inch firmware draws the existing Bicino wordmark after panel
initialization, before storage/map recovery and the remaining application
startup. It gives visible feedback during startup; it does not make the device
ready sooner or change the readiness checkpoint.

The direct panel draw uses the existing RGB565A8 asset, composites it onto black,
and applies the same clockwise rotation as the normal LVGL flush. A 256-byte
stack row buffer avoids another framebuffer allocation. PMIC settings, panel
delays, and the full-screen LVGL refresh strategy are unchanged. The 2.06-inch
path and display test/probe patterns do not draw this logo.

The real waiting screen now replaces this logo before map recovery starts;
see `docs/firmware-startup-sequence.md`.

## Hardware observation

On 2026-10-26, the owner confirmed the connected round 1.75-inch board and
authorized the USB upload of commit
`08c05ea6ff46c9608d16d0b9ff04cd9e15805a85`, built with
`WAVESHARE_AMOLED_175_PRODUCTION`. The repository build helper completed the
upload successfully; esptool verified all four written images and reset the
board. The firmware binary SHA-256 was
`c8b9cf4a77db834a22f35b9915d55a3a8953a9edf1ee061b53f2174be67ad99a`.

The owner was asked to disconnect USB and time a normal PWR-button startup to
the first Bicino logo. They reported **about 5 seconds**, after trying a few
times. Exact sample count and individual readings were not supplied.

The earlier reference was **14 seconds**, from one manual measurement. The
USB hardware identities differ between the two observations, and the earlier
installed firmware/profile was not established. These observations therefore
do not establish a controlled same-board speedup or a change in full startup
time. Historical diagnostic logs also do not measure physical first pixels.

## Validation boundaries

| Target/check | Evidence and remaining gate |
| --- | --- |
| 1.75-inch first visible content | Owner reported approximately 5 seconds over repeated manual startups on the commit above. |
| 1.75-inch orientation and UI handoff | Normal-screen timing and logo orientation were not explicitly reported; these checks remain pending. |
| 1.75-inch running-image acceptance | Production omits serial `BOOT_META`. No independent owner-authenticated `boot/acceptance` record was retrieved. Upload success and visual timing do not replace that record. |
| Complete removal of power | Not qualified: the stopwatch procedure was ordinary button power-off/on, not removal of both battery and USB power. |
| Branch after integrating current main | The tested commit is retained in history. Hardware observations apply to that commit, not automatically to the updated merge candidate. |
| 2.06-inch | No logo behavior change or physical qualification is claimed. |

Host tests cover RGB565 byte order, padded image rows, alpha composition,
clockwise/native placement, and rejection of invalid image bounds. The original
production build and focused host checks passed. Current-head check/build
results belong in the PR's validation record rather than being inferred from
the earlier build.

The production hardware acceptance gate remains open for the unverified items
above. This record is not factory-image qualification or permission to release.
If the early draw causes a display regression, revert the logo change and build
the approved 1.75-inch production revision with `tools/build_firmware.py`; use
the documented USB/BOOT recovery path if the screen is unusable. No storage
migration or firmware-update protocol change needs reversing.
