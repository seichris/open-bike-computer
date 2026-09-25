#!/usr/bin/env python3
"""Verify retained 2021 Copernicus DEM terms and optionally check upstream."""

import argparse
import hashlib
from pathlib import Path
from urllib.request import urlopen


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = (
    (
        "GLO-30 Public",
        "docs/licenses/License-COPDEM-30.pdf",
        "9cd37d37ea654bbcaf0a2e059e6a3a5b5f76072824d8dd860ccf274ada8951bd",
        "https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Data/DEM/resources/license/License-COPDEM-30.pdf",
    ),
    (
        "GLO-90",
        "docs/licenses/copernicus_contributing_mission_data_access_v2_cop_dem_licenses.pdf",
        "bb4a01dcd7f61acefa81c9ccd76af975e12096158169acf0d7b5c44c26c8701f",
        "https://dataspace.copernicus.eu/sites/default/files/media/files/2025-06/copernicus_contributing_mission_data_access_v2_cop_dem_licenses.pdf",
    ),
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--upstream", action="store_true", help="also compare current official downloads"
    )
    args = parser.parse_args()
    valid = True
    for name, path, expected, url in DOCUMENTS:
        local_hash = digest((REPO_ROOT / path).read_bytes())
        print(f"{name} retained: {local_hash}")
        valid &= local_hash == expected
        if args.upstream:
            with urlopen(url, timeout=30) as response:
                upstream_hash = digest(response.read())
            print(f"{name} upstream: {upstream_hash}")
            valid &= upstream_hash == expected
    if not valid:
        print("Reviewed terms changed; stop release and review the exact documents.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
