"""Public notices for the two pinned 2021 Copernicus DEM sources.

The source IDs are intentionally explicit: a new elevation source must supply
its own reviewed notice before the map pipeline can publish its artifacts.
"""

from collections.abc import Mapping
from typing import Any


_COPYRIGHT = (
    "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
    "provided under COPERNICUS by the European Union and ESA; all rights reserved."
)

_PRODUCTS = {
    "copernicus-glo30-public-2021": "Copernicus WorldDEM-30",
    "copernicus-glo90-2021": "Copernicus WorldDEM™-90",
}


def topography_attribution(sample: Mapping[str, Any]) -> bytes:
    sources = sample.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("topography sample has no contributing sources")

    lines = [
        "Bicino contour map elevation source notices.",
        "Contours are derived from a digital surface model, which includes buildings "
        "and vegetation, and are not surveyed bare-earth elevations.",
        "Bicino is not endorsed by the Copernicus DEM provider or programme.",
        "",
    ]
    for source in sources:
        if not isinstance(source, Mapping):
            raise ValueError("topography source attribution is invalid")
        source_id = source.get("sourceId")
        product = _PRODUCTS.get(source_id) if isinstance(source_id, str) else None
        if product is None or source.get("datasetRelease") != "2021":
            raise ValueError("topography source has no reviewed public notice")
        lines.extend(
            [
                f"Source: {source_id}",
                "Dataset release: 2021",
                f"Source notice: {_COPYRIGHT}",
                f"Adapted data notice: produced using {product} {_COPYRIGHT}",
                "Liability notice: The organisations in charge of the Copernicus "
                f"programme by law or by delegation do not incur any liability for any use of the {product}.",
                f"Terms: {source.get('termsUrl')}",
                f"Attribution information: {source.get('attributionUrl')}",
                "",
            ]
        )
    return ("\n".join(lines).rstrip() + "\n").encode("utf-8")
