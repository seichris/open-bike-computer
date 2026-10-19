#!/usr/bin/env python3
"""Render production social badges using pinned LVGL and its fixed TLSF pool."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from generate_ride_stats_preview import lvgl_source_digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lvgl-source', required=True, type=Path)
    args = parser.parse_args()
    lvgl = args.lvgl_source.resolve()
    lock = json.loads((ROOT / 'tools/ride_stats_preview/lvgl-source.lock.json').read_text())
    if lvgl_source_digest(lvgl) != lock['sourceTreeSha256']:
        parser.error('LVGL source does not match the pinned firmware/preview source tree')
    with tempfile.TemporaryDirectory(prefix='bicino-social-render-') as temporary:
        build = Path(temporary)
        # Use every production setting. Only make assertions terminate the host
        # process (rather than hanging), and replace ESP-specific portrait RAM.
        config = (ROOT / 'esp32/lib/lvgl/lv_conf.h').read_text(encoding='utf-8-sig')
        config = config.replace('#define LV_ASSERT_HANDLER while(1);', '#define LV_ASSERT_HANDLER abort();')
        config = config.replace('#define LV_ASSERT_HANDLER_INCLUDE <stdint.h>', '#define LV_ASSERT_HANDLER_INCLUDE <stdlib.h>')
        (build / 'lv_conf.h').write_text(config)
        (build / 'esp_heap_caps.h').write_text('''#pragma once
#include <cstdlib>
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_8BIT 2
inline void *heap_caps_malloc(size_t size, unsigned) { return std::malloc(size); }
''')
        (build / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.16)
project(social_render LANGUAGES C CXX ASM)
set(CMAKE_CXX_STANDARD 17)
set(LV_CONF_PATH "{build}/lv_conf.h" CACHE STRING "" FORCE)
set(LV_CONF_BUILD_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_DEMOS ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_THORVG_INTERNAL ON CACHE BOOL "" FORCE)
add_subdirectory("{lvgl}" lvgl)
add_executable(social_render "{ROOT}/esp32/tools/tests/test_social_riders_render.cpp"
 "{ROOT}/esp32/lib/social_riders/social_riders_view.cpp")
target_include_directories(social_render PRIVATE "{build}" "{ROOT}/esp32/lib/social_riders")
target_link_libraries(social_render PRIVATE lvgl m)
''')
        subprocess.run(['cmake', '-S', str(build), '-B', str(build / 'out'),
                        '-DCMAKE_BUILD_TYPE=Debug'], check=True)
        subprocess.run(['cmake', '--build', str(build / 'out'), '-j', '4'], check=True)
        subprocess.run([str(build / 'out/social_render')], check=True, timeout=60)


if __name__ == '__main__':
    main()
