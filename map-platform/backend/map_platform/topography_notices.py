"""Public notices for the elevation sources Bicino publishes data from.

The two pinned 2021 Copernicus DEM sources serve map contours and route
elevation profiles. The bicycle routing graph also grades its edges with the
terrain models of map-platform/routing/elevation-sources.json.

The source IDs are intentionally explicit: a new elevation source must supply
its own reviewed notice before the map pipeline can publish its artifacts, or
before the route API can credit a graph graded with it.
"""

from collections.abc import Mapping, Sequence
from typing import Any


_COPYRIGHT = (
    "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
    "provided under COPERNICUS by the European Union and ESA; all rights reserved."
)

_PRODUCTS = {
    "copernicus-glo30-public-2021": "Copernicus WorldDEM-30",
    "copernicus-glo90-2021": "Copernicus WorldDEM™-90",
}


def route_elevation_notices(source_ids: Sequence[str]) -> tuple[str, ...]:
    """Reviewed notices for route elevation profiles derived from pinned sources."""
    if not source_ids:
        raise ValueError("route elevation profile has no contributing sources")
    lines = [
        "Route elevation is derived from a digital surface model, which includes "
        "buildings and vegetation, and is not surveyed road elevation.",
        "Bicino is not endorsed by the Copernicus DEM provider or programme.",
    ]
    for source_id in source_ids:
        product = _PRODUCTS.get(source_id)
        if product is None:
            raise ValueError("route elevation source has no reviewed public notice")
        lines.extend(
            [
                f"Source notice: {_COPYRIGHT}",
                f"Adapted data notice: produced using {product} {_COPYRIGHT}",
                "Liability notice: The organisations in charge of the Copernicus "
                f"programme by law or by delegation do not incur any liability for any use of the {product}.",
            ]
        )
    return tuple(lines)


# Credits for the terrain models a routing graph may be graded with, as their
# publishers ask for them (map-platform/routing/elevation-sources.json).
_ROUTING_TERRAIN_CREDITS = {
    "usgs-3dep-13": (
        "U.S. Geological Survey 3D Elevation Program (3DEP), 1/3 arc-second DEM. "
        "Map services and data available from U.S. Geological Survey, National Geospatial Program."
    ),
    "nrcan-mrdem-30": (
        "Natural Resources Canada, Medium Resolution Digital Elevation Model (MRDEM-30), "
        "CanElevation Series. Contains information licensed under the Open Government Licence – Canada "
        "(https://open.canada.ca/en/open-government-licence-canada)."
    ),
    # CC BY 4.0: the credit, the licence and that the data was changed. Three
    # lines, since the app takes none longer than APP_MAXIMUM_LINE_LENGTH.
    "sonny-dtm-europe-1s-v25": (
        "Sonny's LiDAR Digital Terrain Models of Europe (https://sonny.4lima.de), licensed under CC BY 4.0 "
        "(https://creativecommons.org/licenses/by/4.0/). Modified: resampled to 1 arc-second posts and joined "
        "to Copernicus GLO-30. Compiled from the national terrain models its _Datasources.txt lists, among them:",
        "BEV and the Austrian Länder, Digitaal Vlaanderen and the Walloon Region, CUZK, the Danish Agency for "
        "Climate Data, the Estonian Land Board, the National Land Survey of Finland, IGN France, the German "
        "Länder (GeoBasis-DE), the Latvian Geospatial Information Agency, the Lithuanian National Land Service,",
        "ACT Luxembourg, AHN, Kartverket and the Norwegian Polar Institute, GUGiK, GKU Bratislava, the Slovenian "
        "Ministry of the Environment, IGN Spain (LiDAR-PNOA), Lantmateriet, swisstopo, the Environment Agency, "
        "the Welsh and Scottish Governments, Land & Property Services and Ordnance Survey, and the "
        "Direcao-Geral do Territorio.",
    ),
    "linz-nz-lidar-1m-dem": (
        "Sourced from the LINZ Data Service and licensed by Toitu Te Whenua Land Information New Zealand for "
        "re-use under the Creative Commons Attribution 4.0 International licence "
        "(https://creativecommons.org/licenses/by/4.0/). Modified: resampled to 1 arc-second posts and joined "
        "to Copernicus GLO-30."
    ),
    # Both ask for the source to be identified; the wording is the publishers' own.
    "cedd-hk-lidar-dtm-2020": (
        "LiDAR Data 2020 (Digital Terrain Model) of the Civil Engineering and Development Department, from the "
        "Common Spatial Data Infrastructure portal. The Government of the Hong Kong Special Administrative "
        "Region is the owner of the data."
    ),
    "gsi-japan-dem5a-dem10b-20261127": (
        "Made by processing GSI Tiles (elevation tiles, from the Fundamental Geospatial Data digital elevation "
        "model) of the Geospatial Information Authority of Japan."
    ),
}
# The iOS app keeps a list of credits only if it has at most this many lines,
# none longer than this (BicycleRoutingElevationCreditsV1); a longer list
# would show nothing.
APP_MAXIMUM_LINES = 16
APP_MAXIMUM_LINE_LENGTH = 600


def routing_graph_elevation_credits(source_ids: Sequence[str]) -> tuple[str, ...]:
    """Reviewed credits for a bicycle routing graph graded with these sources.

    No sources means a graph without elevation, which credits nothing.
    """
    if len(set(source_ids)) != len(source_ids):
        raise ValueError("routing graph elevation source is listed twice")
    lines: list[str] = []
    copernicus = False
    for source_id in source_ids:
        product = _PRODUCTS.get(source_id)
        if product is not None:
            copernicus = True
            lines.extend(
                [
                    f"Produced using {product} {_COPYRIGHT}",
                    "The organisations in charge of the Copernicus programme by law or by delegation "
                    f"do not incur any liability for any use of the {product}.",
                ]
            )
            continue
        credit = _ROUTING_TERRAIN_CREDITS.get(source_id)
        if credit is None:
            raise ValueError("routing graph elevation source has no reviewed public notice")
        lines.extend((credit,) if isinstance(credit, str) else credit)
    if copernicus:
        lines.append("Bicino is not endorsed by the Copernicus DEM provider or programme.")
    return tuple(lines)


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
