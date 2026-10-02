#!/usr/bin/env python3
"""Generate native-resolution iPhone preview tiles with the actual ESP32 renderer.

Requires a local LVGL 9.2.2 checkout, CMake, a C/C++ compiler and Pillow.
CI uses the existing preconnection-assets Pillow 11.3.0 pin.
Only rendered sample text/images are embedded in the app, not font libraries.
The firmware remains the source of geometry, glyphs, font tiers and HR widgets.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GUI = ROOT / 'esp32/lib/gui/src'
LVGL_COMMIT = '7f07a129e8d77f4984fff8e623fd5be18ff42e74'
ASSETS = ROOT / 'ios-app/BikeComputer/BikeComputer/Assets.xcassets'
FUNCTIONS = (
    'metricFontRole', 'metricValueRect', 'setLabelIfChanged',
    'setMetricTitleIfChanged', 'applyMetricText', 'setMetricValueIfChanged',
    'setHeartValue', 'createMetricTitle', 'createMetric', 'drawHeartIcon',
    'createHeartIcon', 'setConfigurableSlotHidden', 'createConfigurableSlot',
    'updateConfigurableZone', 'updateConfigurableSlots',
)
INPUTS = (
    'protocol/ride-ble-contract-v1.json',
    'esp32/lib/ble_navigation/ride_ble_protocol.generated.hpp',
    'esp32/lib/ble_navigation/screen_configuration_protocol.hpp',
    'esp32/lib/ble_navigation/workout_zone_wire.generated.hpp',
    'esp32/lib/ble_navigation/workout_zone_protocol.hpp',
    'esp32/lib/gui/src/rideMetricTypography.hpp',
    'esp32/lib/gui/src/rideMetricFontSelection.hpp',
    'esp32/lib/gui/src/rideTelemetryLayout.hpp',
    'esp32/lib/gui/src/rideTelemetryPresenter.hpp',
    'esp32/lib/gui/src/ride_stats_widget.hpp',
    'esp32/lib/gui/src/rideValueFont56.c',
    'esp32/lib/gui/src/rideValueFont64.c',
    'esp32/lib/gui/src/rideSpeedFont84.c',
    'tools/ride_stats_preview/emit_preview.cpp',
    'tools/ride_stats_preview/lv_conf.h',
    'tools/ride_stats_preview/lvgl-source.lock.json',
    'tools/generate_ride_stats_preview.py',
)


def renderer_helpers() -> str:
    source = (GUI / 'rideTelemetryScr.cpp').read_text()
    structs = source[source.index('struct MetricLabels {'):source.index('lv_obj_t *ridePage')]
    parts = [structs, 'std::array<ConfigurableSlotView, 7> configurableSlots{};\n']
    for name in FUNCTIONS:
        match = re.search(r'^[A-Za-z_][A-Za-z_0-9:* ]*\b' + name + r'\(', source, re.M)
        if match is None:
            raise ValueError(f'Cannot locate renderer function: {name}')
        end = source.index('\n}\n', match.start()) + 3
        parts.append(source[match.start():end])
    return '\n'.join(parts)


def source_hashes() -> dict[str, str]:
    return {**{name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in INPUTS},
            'renderer_helpers': hashlib.sha256(renderer_helpers().encode()).hexdigest()}


def lvgl_source_digest(lvgl: Path) -> str:
    paths = [p for directory in ('src', 'env_support/cmake')
             for p in (lvgl / directory).rglob('*') if p.is_file()]
    paths.extend(lvgl / name for name in
                 ('CMakeLists.txt', 'lvgl.h', 'lv_version.h', 'lv_version.h.in', 'lvgl.pc.in'))
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(lvgl).as_posix().encode() + b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def emit(lvgl: Path, build: Path, output: Path) -> None:
    build.mkdir(parents=True, exist_ok=True)
    (build / 'renderer_helpers.inc').write_text(renderer_helpers())
    cmake = f'''cmake_minimum_required(VERSION 3.16)
project(ride_preview LANGUAGES C CXX ASM)
set(CMAKE_CXX_STANDARD 17)
set(LV_CONF_PATH "{ROOT}/tools/ride_stats_preview/lv_conf.h" CACHE STRING "" FORCE)
set(LV_CONF_BUILD_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_DEMOS ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_THORVG_INTERNAL ON CACHE BOOL "" FORCE)
add_subdirectory("{lvgl}" lvgl)
add_executable(emit_preview "{ROOT}/tools/ride_stats_preview/emit_preview.cpp"
 "{GUI}/rideValueFont56.c" "{GUI}/rideValueFont64.c" "{GUI}/rideSpeedFont84.c")
target_include_directories(emit_preview PRIVATE "{GUI}" "{build}")
target_link_libraries(emit_preview PRIVATE lvgl m)
'''
    (build / 'CMakeLists.txt').write_text(cmake)
    subprocess.run(['cmake', '-S', str(build), '-B', str(build / 'out'),
                    '-DCMAKE_BUILD_TYPE=Debug'], check=True)
    subprocess.run(['cmake', '--build', str(build / 'out'), '-j', '4'], check=True)
    subprocess.run([str(build / 'out/emit_preview'), str(output)], check=True)


def pack(output: Path) -> tuple[bytes, bytes]:
    from PIL import Image
    spec = json.loads((output / 'preview.json').read_text())
    spec['sourceHashes'] = source_hashes()
    spec['lvglCommit'] = LVGL_COMMIT
    images = {}
    for board in spec['boards'].values():
        for group in ('normal', 'pairs'):
            for tile in board[group].values():
                filename = tile.pop('file')
                if not filename:
                    tile['sprite'] = None
                    continue
                _, _, width, height = tile['bounds']
                data = (output / filename).read_bytes()
                key = hashlib.sha256(f'{width}:{height}:'.encode() + data).hexdigest()[:20]
                tile['sprite'] = key
                images[key] = Image.frombytes('RGBA', (width, height), data, 'raw', 'BGRA')
    placements = {}
    x = y = row_height = 0
    atlas_width = 2048
    for key, image in sorted(images.items(), key=lambda item: (-item[1].height, item[0])):
        if x + image.width + 1 > atlas_width:
            x = 0
            y += row_height + 1
            row_height = 0
        placements[key] = [x, y, image.width, image.height]
        x += image.width + 1
        row_height = max(row_height, image.height)
    atlas = Image.new('RGBA', (atlas_width, y + row_height + 1))
    for key, image in images.items():
        atlas.paste(image, tuple(placements[key][:2]))
    spec['sprites'] = placements
    import io
    buffer = io.BytesIO()
    atlas.save(buffer, format='PNG', optimize=False, compress_level=9)
    return (json.dumps(spec, sort_keys=True, separators=(',', ':')) + '\n').encode(), buffer.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lvgl-source', required=True, type=Path)
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    lvgl = args.lvgl_source.resolve()
    if not (lvgl / 'src/font/lv_font_montserrat_38.c').is_file():
        parser.error('Provide the LVGL 9.2.2 source checkout')
    lock = json.loads((ROOT / 'tools/ride_stats_preview/lvgl-source.lock.json').read_text())
    if lvgl_source_digest(lvgl) != lock['sourceTreeSha256']:
        parser.error('LVGL renderer/font source does not match the pinned clean source tree')
    # Check identity as well when a Git checkout is supplied. The tree digest
    # also catches dirty files and verifies exported source archives.
    if (lvgl / '.git').exists():
        head = subprocess.check_output(['git','-C',str(lvgl),'rev-parse','HEAD'],text=True).strip()
        if head != LVGL_COMMIT:
            parser.error(f'LVGL checkout must be {LVGL_COMMIT}')
    with tempfile.TemporaryDirectory(prefix='ride-preview-') as temporary:
        output = Path(temporary) / 'rendered'
        build = args.build_dir.resolve() if args.build_dir else Path(temporary) / 'build'
        emit(lvgl, build, output)
        spec, png = pack(output)
        products = {
            ASSETS/'RideStatsPreview.dataset/preview.json': spec,
            ASSETS/'RideStatsPreview.dataset/Contents.json': b'{"data":[{"filename":"preview.json","idiom":"universal"}],"info":{"author":"xcode","version":1}}\n',
            ASSETS/'RideStatsPreviewAtlas.imageset/atlas.png': png,
            ASSETS/'RideStatsPreviewAtlas.imageset/Contents.json': b'{"images":[{"filename":"atlas.png","idiom":"universal","scale":"1x"}],"info":{"author":"xcode","version":1}}\n',
        }
        for path, data in products.items():
            if args.check:
                if path.suffix == '.png' and path.is_file():
                    import io
                    from PIL import Image
                    actual = Image.open(path).convert('RGBA')
                    expected = Image.open(io.BytesIO(data)).convert('RGBA')
                    same = actual.size == expected.size and actual.tobytes() == expected.tobytes()
                else:
                    same = path.is_file() and path.read_bytes() == data
                if not same:
                    raise SystemExit(f'Preview needs regeneration: {path.relative_to(ROOT)}')
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        print(f'Ride Stats preview: {len(spec)} JSON bytes, {len(png)} PNG bytes; '
              + ('up to date' if args.check else 'generated'))

if __name__ == '__main__':
    main()
