import struct

from feature_types import get_type_id


def write_fmb(path, polygons, polylines, min_x, min_y):
    """Write one version-2 binary map block."""
    with open(path, "wb") as file:
        file.write(b"FMB\x02")

        file.write(struct.pack("<H", len(polygons)))
        for feature in polygons:
            color = (
                int(feature["color"], 16)
                if isinstance(feature["color"], str)
                else int(feature["color"])
            )
            max_zoom = (
                int(feature["maxzoom"])
                if feature["maxzoom"] not in ("", None)
                else 15
            )

            file.write(struct.pack("<H", color))
            file.write(struct.pack("<B", max_zoom))
            file.write(struct.pack("<B", get_type_id(feature["type"])))
            file.write(
                struct.pack(
                    "<hhhh",
                    int(round(feature["bbox"][0] - min_x)),
                    int(round(feature["bbox"][1] - min_y)),
                    int(round(feature["bbox"][2] - min_x)),
                    int(round(feature["bbox"][3] - min_y)),
                )
            )

            coordinates = list(feature["geom"].exterior.coords)
            file.write(struct.pack("<H", len(coordinates)))
            for x, y in coordinates:
                file.write(
                    struct.pack(
                        "<hh", int(round(x - min_x)), int(round(y - min_y))
                    )
                )

        file.write(struct.pack("<H", len(polylines)))
        for feature in polylines:
            color = (
                int(feature["color"], 16)
                if isinstance(feature["color"], str)
                else int(feature["color"])
            )
            width = int(feature["width"]) if feature["width"] is not None else 1
            max_zoom = (
                int(feature["maxzoom"])
                if feature["maxzoom"] not in ("", None)
                else 15
            )

            file.write(struct.pack("<H", color))
            file.write(struct.pack("<B", width))
            file.write(struct.pack("<B", max_zoom))
            file.write(struct.pack("<B", get_type_id(feature["type"])))
            file.write(
                struct.pack(
                    "<hhhh",
                    int(round(feature["bbox"][0] - min_x)),
                    int(round(feature["bbox"][1] - min_y)),
                    int(round(feature["bbox"][2] - min_x)),
                    int(round(feature["bbox"][3] - min_y)),
                )
            )

            coordinates = list(feature["geom"].coords)
            file.write(struct.pack("<H", len(coordinates)))
            for x, y in coordinates:
                file.write(
                    struct.pack(
                        "<hh", int(round(x - min_x)), int(round(y - min_y))
                    )
                )
