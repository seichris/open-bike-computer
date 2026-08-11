import base64
import hashlib
import io
import json
from pathlib import Path
import re
import unittest

from PIL import Image
import qrcode
from qrcode.constants import ERROR_CORRECT_M
import zxingcpp

from tools import generate_preconnection_assets as assets


EXPECTED_LOGO_ALPHA_SHA256 = (
    "f94e70c64e0847fa4d4b0cb1a0a968fdc414ffadac31a8d83fe6e7458258b771"
)


def _asset_bytes(path: Path, symbol: str) -> bytes:
    source = path.read_text()
    match = re.search(
        rf"{re.escape(symbol)}_map\[\].*?=\s*\{{(.*?)\}};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing {symbol}_map initializer")
    return bytes(
        int(value, 16)
        for value in re.findall(r"0x([0-9a-fA-F]{2})", match.group(1))
    )


def _asset_descriptor(
    path: Path, symbol: str
) -> tuple[tuple[str, ...], str, str, str]:
    source = path.read_text()
    match = re.search(
        rf"const\s+lv_image_dsc_t\s+{re.escape(symbol)}\s*=\s*\{{"
        r"\s*\{\s*(.*?)\s*\}\s*,\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*\};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing complete {symbol} descriptor")
    header_source = match.group(1).strip().rstrip(",")
    header = tuple(field.strip() for field in header_source.split(","))
    if len(header) != 7:
        raise AssertionError(f"unexpected {symbol} header fields: {header}")
    return header, *(field.strip() for field in match.groups()[1:])


def _expected_logo_alpha(source: bytes) -> bytes:
    original = Image.open(io.BytesIO(source)).convert("RGBA")
    alpha_bounds = original.getchannel("A").getbbox()
    if alpha_bounds is None:
        raise AssertionError("canonical logo has no visible alpha")
    mark = original.crop(alpha_bounds)
    mark.thumbnail((assets.LOGO_SIZE, assets.LOGO_SIZE), Image.Resampling.LANCZOS)
    expected = Image.new("L", (assets.LOGO_SIZE, assets.LOGO_SIZE), 0)
    expected.paste(
        mark.getchannel("A"),
        (
            (assets.LOGO_SIZE - mark.width) // 2,
            (assets.LOGO_SIZE - mark.height) // 2,
        ),
    )
    return expected.tobytes()


class PreconnectionAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(assets.MANIFEST.read_text())

    def test_manifest_and_generated_file_checksums(self) -> None:
        self.assertEqual(
            self.manifest["generator"],
            "tools/generate_preconnection_assets.py",
        )
        for relative_path, expected_hash in self.manifest["outputs"].items():
            content = (assets.ROOT / relative_path).read_bytes()
            self.assertEqual(hashlib.sha256(content).hexdigest(), expected_hash)

    def test_logo_matches_pinned_source_and_brand_color(self) -> None:
        source = base64.b64decode(assets.SOURCE_B64.read_text())
        self.assertEqual(
            hashlib.sha256(source).hexdigest(), assets.LOGO_SOURCE_SHA256
        )
        self.assertEqual(
            self.manifest["logo"]["source_commit"], assets.LOGO_SOURCE_COMMIT
        )
        self.assertEqual(
            self.manifest["logo"]["source_sha256"], assets.LOGO_SOURCE_SHA256
        )
        self.assertEqual(self.manifest["logo"]["color_rgb888"], "#FF372E")

        source_path = assets.OUTPUT / "bicino_logo.c"
        self.assertEqual(
            _asset_descriptor(source_path, "bicino_logo"),
            (
                (
                    "LV_IMAGE_HEADER_MAGIC",
                    "LV_COLOR_FORMAT_RGB565A8",
                    "0",
                    "36",
                    "36",
                    "72",
                    "0",
                ),
                "sizeof(bicino_logo_map)",
                "bicino_logo_map",
                "NULL",
            ),
        )
        data = _asset_bytes(source_path, "bicino_logo")
        pixel_count = assets.LOGO_SIZE * assets.LOGO_SIZE
        self.assertEqual(len(data), pixel_count * 3)
        rgb565 = (
            ((assets.BRAND_RED[0] >> 3) << 11)
            | ((assets.BRAND_RED[1] >> 2) << 5)
            | (assets.BRAND_RED[2] >> 3)
        )
        self.assertEqual(
            data[: pixel_count * 2],
            bytes((rgb565 & 0xFF, rgb565 >> 8)) * pixel_count,
        )
        alpha = data[pixel_count * 2 :]
        self.assertIn(0, alpha)
        self.assertGreater(max(alpha), 0)
        self.assertEqual(alpha, _expected_logo_alpha(source))
        self.assertEqual(
            hashlib.sha256(alpha).hexdigest(), EXPECTED_LOGO_ALPHA_SHA256
        )
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            self.manifest["logo"]["data_sha256"],
        )

    def test_checked_in_qr_matches_exact_payload_matrix(self) -> None:
        source_path = assets.OUTPUT / "bicino_app_qr.c"
        self.assertEqual(
            _asset_descriptor(source_path, "bicino_app_qr"),
            (
                (
                    "LV_IMAGE_HEADER_MAGIC",
                    "LV_COLOR_FORMAT_I1",
                    "0",
                    "165",
                    "165",
                    "21",
                    "0",
                ),
                "sizeof(bicino_app_qr_map)",
                "bicino_app_qr_map",
                "NULL",
            ),
        )
        data = _asset_bytes(source_path, "bicino_app_qr")
        self.assertEqual(
            data[:8],
            bytes((0, 0, 0, 255, 255, 255, 255, 255)),
        )
        stride = self.manifest["qr"]["stride_bytes"]
        pixels = data[8:]
        self.assertEqual(len(pixels), stride * assets.QR_SIZE)

        grayscale = bytes(
            255
            if pixels[y * stride + x // 8] & (1 << (7 - x % 8))
            else 0
            for y in range(assets.QR_SIZE)
            for x in range(assets.QR_SIZE)
        )
        image = Image.frombytes(
            "L", (assets.QR_SIZE, assets.QR_SIZE), grayscale
        )
        decoded = zxingcpp.read_barcodes(
            image, formats=zxingcpp.BarcodeFormat.QRCode, is_pure=True
        )
        self.assertEqual([barcode.text for barcode in decoded], [assets.QR_PAYLOAD])

        modules = []
        for module_y in range(assets.QR_TOTAL_MODULES):
            row = []
            for module_x in range(assets.QR_TOTAL_MODULES):
                values = {
                    not bool(
                        pixels[y * stride + x // 8]
                        & (1 << (7 - x % 8))
                    )
                    for y in range(
                        module_y * assets.QR_MODULE_SCALE,
                        (module_y + 1) * assets.QR_MODULE_SCALE,
                    )
                    for x in range(
                        module_x * assets.QR_MODULE_SCALE,
                        (module_x + 1) * assets.QR_MODULE_SCALE,
                    )
                }
                self.assertEqual(len(values), 1, "QR module was resampled")
                row.append(values.pop())
            modules.append(row)

        qr = qrcode.QRCode(
            version=assets.QR_VERSION,
            error_correction=ERROR_CORRECT_M,
            box_size=1,
            border=assets.QR_BORDER_MODULES,
        )
        qr.add_data(assets.QR_PAYLOAD)
        qr.make(fit=False)
        self.assertEqual(modules, qr.get_matrix())
        self.assertEqual(self.manifest["qr"]["payload"], "https://bicino.com/app")
        self.assertEqual(self.manifest["qr"]["version"], 2)
        self.assertEqual(self.manifest["qr"]["error_correction"], "M")
        self.assertEqual(self.manifest["qr"]["quiet_zone_modules"], 4)
        self.assertEqual(self.manifest["qr"]["module_scale"], 5)
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            self.manifest["qr"]["data_sha256"],
        )

    def test_waiting_screen_has_no_technical_badge_labels(self) -> None:
        source = (
            assets.ROOT / "lib" / "gui" / "src" / "waitingScr.cpp"
        ).read_text()
        string_literals = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', source)
        self.assertTrue({"ADD", "PAIR", "AUTH", "LINK"}.isdisjoint(string_literals))


if __name__ == "__main__":
    unittest.main()
