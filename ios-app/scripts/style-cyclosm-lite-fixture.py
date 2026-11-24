#!/usr/bin/env python3
"""Restyle local CyclOSM Lite PNG tiles for Bicino Simulator's bike-lane prototype."""

from argparse import ArgumentParser
from pathlib import Path

from PIL import Image, ImageFilter


def restyle(source: Path, destination: Path) -> int:
    if not source.is_dir() or source == destination or source in destination.parents:
        raise ValueError("Use separate source and output directories.")

    count = 0
    for tile in sorted(source.glob("*/*/*.png")):
        with Image.open(tile) as image:
            alpha = image.convert("RGBA").getchannel("A")
        # Soften a one-pixel border while retaining narrow markings whose
        # strokes would disappear with a full erosion.
        inset = alpha.filter(ImageFilter.MinFilter(3))
        alpha = Image.blend(alpha, inset, 0.45).point(lambda opacity: round(opacity * 0.78))
        styled = Image.new("RGBA", alpha.size, (0, 115, 108))
        styled.putalpha(alpha)
        output = destination / tile.relative_to(source)
        output.parent.mkdir(parents=True, exist_ok=True)
        styled.save(output, optimize=True)
        count += 1
    return count


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(f"Styled {restyle(args.source.resolve(), args.destination.resolve())} tiles.")
