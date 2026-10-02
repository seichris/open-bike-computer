import sys
import hashlib
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from firmware_release_history import validate_build, published_builds, TARGETS


class FirmwareReleaseHistoryTests(unittest.TestCase):
    def test_history_reads_all_pages_and_verifies_the_target_pair(self):
        repository = "owner/repo"
        bodies = {}
        assets = []
        for target in TARGETS:
            url = f"https://github.com/{repository}/releases/download/v1.0.0/{target}.manifest.json"
            data = json.dumps({"target": target, "build": 93}).encode()
            bodies[url] = data
            assets.append({"name": f"{target}.manifest.json", "browser_download_url": url,
                           "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
        pages = [[{"tag_name": "runtime", "assets": []}], [{"tag_name": "v1.0.0", "assets": assets}]]

        def download(url, **kwargs):
            stream = io.BytesIO(bodies[url])
            stream.url = url
            return stream

        with patch("firmware_release_history.subprocess.check_output", return_value=json.dumps(pages).encode()) as command, \
             patch("firmware_release_history.urllib.request.urlopen", side_effect=download):
            self.assertEqual(published_builds(repository), [93])
            self.assertIn("--paginate", command.call_args.args[0])
            bodies[assets[0]["browser_download_url"]] += b" "
            with self.assertRaisesRegex(ValueError, "asset digest"):
                published_builds(repository)
        assets.pop()
        with patch("firmware_release_history.subprocess.check_output", return_value=json.dumps(pages).encode()), \
             patch("firmware_release_history.urllib.request.urlopen", side_effect=download):
            # Restore first body, so this specifically reaches missing board two.
            bodies[assets[0]["browser_download_url"]] = bodies[assets[0]["browser_download_url"]][:-1]
            with self.assertRaisesRegex(ValueError, "incomplete target pair"):
                published_builds(repository)

    def test_same_lower_and_invalid_builds_are_rejected(self):
        for candidate in (93, 92, 0, -1, True, "94", 2**32):
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                validate_build(candidate, [87, 93, 88])

    def test_revert_with_new_build_and_first_publication(self):
        validate_build(94, [87, 93])
        validate_build(1, [])

    def test_out_of_order_publication_and_recovery(self):
        validate_build(95, [93])
        with self.assertRaises(ValueError):
            validate_build(94, [93, 95])
        validate_build(95, [93, 95], recovery=True)
        with self.assertRaises(ValueError):
            validate_build(93, [93, 95], recovery=True)
        validate_build(93, [93, 95], recovery=True, allow_older=True)


if __name__ == "__main__":
    unittest.main()
