# Waveshare ESP32-S3-ePaper-3.97 references

Collected on 2026-09-12 from the official
[board documentation](https://docs.waveshare.com/ESP32-S3-ePaper-3.97) and
[English resources page](https://docs.waveshare.com/ESP32-S3-ePaper-3.97/Resources-And-Documents).
This collection accompanies the
[firmware implementation plan](../../../../docs/plans/waveshare-epaper-397-firmware-implementation-plan.md).
The material establishes vendor documentation and source evidence; it does not
establish that Bicino firmware runs on a physical 3.97-inch board.

## Downloaded documents

All nine PDF links in sections 1 and 2 of the resources page are stored here.
Files retain the downloaded bytes, with normalized local names. These are a
board-specific snapshot, so shared component PDFs elsewhere in the repository
are not replaced.

| Document | Local copy | Source |
| --- | --- | --- |
| Board schematic | [PDF](esp32-s3-epaper-3.97-schematic.pdf) | [Waveshare](https://files.waveshare.com/wiki/ESP32-S3-ePaper-3.97/ESP32-S3_e-Paper-3.97-schematic.pdf) |
| ESP32-S3 datasheet, Chinese | [PDF](esp32-s3-datasheet-cn.pdf) | [Espressif](https://documentation.espressif.com/esp32-s3_datasheet_cn.pdf) |
| ESP32-S3 datasheet, English | [PDF](esp32-s3-datasheet-en.pdf) | [Espressif](https://documentation.espressif.com/esp32-s3_datasheet_en.pdf) |
| ESP32-S3 technical reference manual, Chinese | [PDF](esp32-s3-technical-reference-manual-cn.pdf) | [Espressif](https://documentation.espressif.com/esp32-s3_technical_reference_manual_cn.pdf) |
| ESP32-S3 technical reference manual, English | [PDF](esp32-s3-technical-reference-manual-en.pdf) | [Espressif](https://documentation.espressif.com/esp32-s3_technical_reference_manual_en.pdf) |
| 3.97-inch e-paper panel datasheet | [PDF](3.97inch-epaper-datasheet.pdf) | [Waveshare](https://files.waveshare.com/wiki/3.97inch_e-Paper_HAT%2B/3.97inch_e-Paper.pdf) |
| ES8311 datasheet | [PDF](es8311-datasheet.pdf) | [Waveshare](https://files.waveshare.com/wiki/common/ES8311.DS.pdf) |
| PCF85063A datasheet | [PDF](pcf85063a-datasheet.pdf) | [Waveshare](https://files.waveshare.com/wiki/common/Pcf85063atl1118-NdPQpTGE-loeW7GbZ7.pdf) |
| SHTC3 datasheet | [PDF](shtc3-datasheet.pdf) | [Waveshare](https://files.waveshare.com/wiki/common/SHTC3_Datasheet.pdf) |

The English resource page did not link a dimension drawing, TG28 datasheet,
QMI8658 datasheet, or separate example ZIP at collection time. The Chinese page
and product listing have different inventories; this collection records the
specific English page requested, without representing those missing items as
downloaded.

## Complete official examples

- Repository: [waveshareteam/ESP32-S3-ePaper-3.97](https://github.com/waveshareteam/ESP32-S3-ePaper-3.97).
- Commit: [`9b12d40731a80213b927ee8a421cae4082952819`](https://github.com/waveshareteam/ESP32-S3-ePaper-3.97/tree/9b12d40731a80213b927ee8a421cae4082952819).
- Local source: [`examples/vendor/`](examples/vendor/), containing **all 982
  upstream files**, including Arduino examples/libraries, ESP-IDF examples,
  fonts/assets, factory/demo firmware, configuration, and license notices.
- Entry points: [vendor README](examples/vendor/README.md),
  [Arduino](examples/vendor/Arduino/), [ESP-IDF](examples/vendor/ESP-IDF/), and
  [vendor firmware](examples/vendor/Firmware/).

The repository archive was downloaded in full and checked for ZIP integrity.
Its 132,313,823-byte ZIP exceeds
[GitHub's 100 MiB per-file limit](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github),
so this branch stores the fully expanded original files. The largest individual upstream file
is 16,777,216 bytes. No Git LFS configuration is needed. Every extracted file's
Git blob hash was matched against the exact upstream commit's recursive tree;
source files have not been adapted for Bicino. The scoped `.gitattributes`
preserves original line endings and marks these files as vendor material.

The `Firmware/` binaries are vendor demonstrations retained as reference. They
have not been executed or flashed and are not attested Bicino releases. The
vendor archive is not part of the project's active build or locked runtime.
Preserve the original license notices when reusing individual source files.

## Provenance and verification

[`SOURCES.json`](SOURCES.json) records each PDF's exact source/resolved URL,
download timestamp, content type, byte size, and SHA-256. It also records the
source archive URL/hash/commit and every extracted file's size, SHA-256, upstream
Git blob hash, and executable mode.

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

## Other links on the resources page

General software installers and flash tools were excluded at the user's
request. The following are indexed for completeness and have not been
downloaded or installed:

- [Arduino IDE download page](https://www.arduino.cc/en/software/).
- [ESP32-Arduino documentation](https://docs.espressif.com/projects/arduino-esp32/en/latest/index.html).
- [Arduino offline component folder](https://drive.google.com/drive/folders/1YhHg8AA_02LFW2OqChk3hbFRV_GVt9Y0),
  listing 19 Windows installers at collection time.
- [VS Code download page](https://code.visualstudio.com/download).
- [Espressif flash download tool](https://dl.espressif.com/public/flash_download_tool.zip).

The community showcase points to external projects and websites, rather than
additional official board downloads. Those projects were not recursively
mirrored:

- FolloUp: [YouTube](https://www.youtube.com/shorts/dGzTLk4jWNE),
  [MakerWorld](https://makerworld.com/en/models/3180226-folloup),
  [GitHub](https://github.com/alxv2016/folloup-sticky/tree/folloup-waveshare).
- CrossMux: [website](https://crossmux.com/),
  [GitHub](https://github.com/0x1abin/crossmux), with an additional link to
  [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader).
- Rustmix Wave: [GitHub](https://github.com/aimindseye/rustmix-wave) and
  [Reddit post](https://www.reddit.com/r/esp32projects/comments/1tyngwy/rustmix_wave_v100_an_opensource_rust_firmware_for/).
