# Waveshare ESP32-S3-Touch-AMOLED-1.75-G (GNSS) references

Collected on 2026-11-08 for the GNSS variant of the 1.75 board, Waveshare's
"-G" model (SKU 31264): the plain board with a Quectel LC76G receiver on
footprint Q1 and a ceramic antenna. The plain board's documents (schematic,
dimension drawings, ESP32-S3 manuals) live in
[waveshare-amoled-175](../waveshare-amoled-175/) and apply unchanged; this
folder holds what the receiver adds. The firmware side is described in
[waveshare-amoled-175-gnss.md](../../../waveshare-amoled-175-gnss.md). The
material establishes vendor documentation and source evidence; it does not by
itself establish that Bicino firmware runs on a physical "-G" board.

## Downloaded documents

| Document | Local copy | Source |
| --- | --- | --- |
| Quectel LC26G/LC76G/LC86G GNSS protocol specification, V1.0.0 preliminary (NMEA output, `$PAIR` commands) | [PDF](quectel-lc26g-lc76g-lc86g-gnss-protocol-specification-v1.0.0-preliminary.pdf) | [Waveshare](https://files.waveshare.com/upload/0/06/Quectel_LC26G%26LC76G%26LC86G_GNSS_Protocol_Specification_V1.0.0_Preliminary.pdf) |
| LC76G GNSS module manual (Waveshare's module) | [PDF](lc76g-gnss-module-manual.pdf) | [Waveshare](https://files.waveshare.com/wiki/LC76G/manual/LC76G%20GNSS%20Module.pdf) |

Both are linked from the
[LC76G GNSS Module wiki](https://www.waveshare.com/wiki/LC76G_GNSS_Module).
The board's own
[resources page](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75/Resources-And-Documents)
links no GNSS document; its schematic and 3D archives are the plain board's
and are already collected. The schematic in the board repository is
byte-identical to the stored
[plain-board copy](../waveshare-amoled-175/esp32-s3-touch-amoled-1.75-schematic.pdf)
(hash in `SOURCES.json`), so it is not duplicated here; the receiver is
footprint Q1 on it, with link resistors R15/R16 to GPIO18/GPIO17 and
`GPS_RST` on the TCA9554.

## Vendor sources

- Board repository
  [waveshareteam/ESP32-S3-Touch-AMOLED-1.75](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75)
  at commit
  [`e4344e70`](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/tree/e4344e70c2fa78a13e8a06566507f1ba8af6672a)
  (Apache-2.0): [`vendor/board-repository/`](vendor/board-repository/) holds
  its [hardware reference](vendor/board-repository/HARDWARE_REFERENCE.md)
  (board variants, the GPIO table with the LC76G rows, the I2C address table,
  the TCA9554 `GPS_RST` assignment, the integration notes), the Chinese
  reference, both readmes, the license and the
  [`09_LC76G_I2C` Arduino example](vendor/board-repository/examples/arduino/09_LC76G_I2C/09_LC76G_I2C.ino),
  the only GNSS source in that repository. Its maintained ESP-IDF BSP has no
  GNSS component.
- Raspberry Pi I2C driver
  [`LC76G_RPI_I2C.zip`](https://files.waveshare.com/wiki/LC76G/Demo/I2C/LC76G_RPI_I2C.zip)
  from the LC76G wiki, the code the ESP example says it is based on:
  [`vendor/lc76g-rpi-i2c/`](vendor/lc76g-rpi-i2c/) holds its sources,
  makefile and readme; the archive's `obj/` build products are omitted and
  indexed by name in `SOURCES.json`. `inc/I2C/i2c_register.h` defines the
  register scheme below.
- Module demo
  [`LC76G_GPS_Module_code.zip`](https://files.waveshare.com/upload/d/dc/LC76G_GPS_Module_code.zip)
  from the LC76G wiki: only the ESP32 UART driver
  ([`vendor/lc76g-module-demo/ESP32/L76X/`](vendor/lc76g-module-demo/ESP32/L76X/),
  `$PAIR`/`$PMTK` command helpers and NMEA parsing) is stored; the archive's
  other platforms carry the same driver and are indexed, not stored.

## What the material establishes

- The "-G" model's receiver is reached over the shared I2C bus. The hardware
  reference lists `0x50`/`0x54` for the LC76G and calls the UART routing to
  GPIO17/GPIO18 optional ("confirm the fitted UART routing"); on the bench
  unit those lines float (see the firmware page's evidence table).
- Quectel's I2C slave scheme, from `i2c_register.h` and the ESP example:
  three 7-bit addresses, `0x50` for command registers, `0x54` to read data
  from the module, `0x58` to write data to it. A command is 8 bytes, the
  register as a 32-bit little-endian value followed by a 32-bit
  little-endian length. Registers: `0xAA510008` (CR) answers with the number
  of bytes the module has buffered (write the command, read 4 bytes from
  `0x54`); `0xAA512000` (RD) is the buffered NMEA stream (write the command
  with the wanted length, read that many bytes from `0x54`); `0xAA510004`
  (CW) answers with the free space for host writes; `0xAA531000` (WR) is the
  host-to-module stream (`$PAIR…` commands go to `0x58` after the WR
  command). The module buffers up to 4096 bytes. The ESP example waits
  100 ms between a command and its answer; the Raspberry Pi driver waits
  10 ms, retries 20 times and uses a 200 ms I2C timeout.
- The ESP example runs the bus at 100 kHz; the hardware reference notes the
  BSP's 400 kHz default and asks the application to pick a rate every device
  supports. Bicino runs this bus at 100 kHz.
- The receiver's RESET is TCA9554 P7 (`GPS_RST`), active low. Its NMEA
  sentences and `$PAIR` configuration commands are in the protocol
  specification; the module manual covers the module's electrical and
  antenna characteristics.

## Provenance and verification

[`SOURCES.json`](SOURCES.json) records each document's source and resolved
URL, download time, content type, size and SHA-256; the board repository's
commit and each copied file's Git blob hash; and each archive's URL, hash,
full entry list and what was stored from it.

To verify the local material, run from this directory:

```sh
python3 - <<'PY'
from pathlib import Path
import hashlib
import json

manifest = json.loads(Path("SOURCES.json").read_text())
for entry in manifest["files"] + manifest["vendor_files"]:
    path = Path(entry["path"])
    data = path.read_bytes()
    assert len(data) == entry["bytes"], path
    assert hashlib.sha256(data).hexdigest() == entry["sha256"], path
    if "git_blob_sha1" in entry:
        blob = b"blob " + str(len(data)).encode() + b"\0" + data
        assert hashlib.sha1(blob).hexdigest() == entry["git_blob_sha1"], path
print("Verified", len(manifest["files"]), "PDFs and",
      len(manifest["vendor_files"]), "vendor files")
PY
```
