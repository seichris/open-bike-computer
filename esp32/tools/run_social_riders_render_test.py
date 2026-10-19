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

# Each AMOLED board's panel, rendered against the same production pool branch.
DISPLAYS = (
    ('466', '466', 'round'),  # 1.75-inch
    ('410', '502', 'rect'),   # 2.06-inch
)
# Host stand-in for ESP-IDF heap capabilities, valid as C and C++. It serves the
# production PSRAM pool branch (LV_MEM_POOL_ALLOC) and counts pool allocations
# so the test can prove which allocator branch it exercised.
HEAP_CAPS_STUB = '''#pragma once
#include <stdint.h>
#include <stdlib.h>
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_8BIT 2
#ifdef __cplusplus
extern "C" {
#endif
extern unsigned bicino_host_psram_pool_allocations;
#ifdef __cplusplus
}
#endif
static inline void *heap_caps_malloc(size_t size, unsigned caps) { (void)caps; return malloc(size); }
static inline void *heap_caps_aligned_alloc(size_t alignment, size_t size, unsigned caps) {
    (void)caps;
    void *memory = malloc(size);
    if (memory && (uintptr_t)memory % alignment != 0) { free(memory); return NULL; }
    if (memory) ++bicino_host_psram_pool_allocations;
    return memory;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lvgl-source', required=True, type=Path)
    args = parser.parse_args()
    lvgl = args.lvgl_source.resolve()
    lock = json.loads((ROOT / 'tools/ride_stats_preview/lvgl-source.lock.json').read_text())
    if lvgl_source_digest(lvgl) != lock['sourceTreeSha256']:
        parser.error('LVGL source does not match the pinned firmware/preview source tree')
    # Use the production configuration unmodified. Its assertion handler must
    # terminate, so an allocation failure fails the test instead of hanging it.
    config = (ROOT / 'esp32/lib/lvgl/lv_conf.h').read_text(encoding='utf-8-sig')
    if '#define LV_ASSERT_HANDLER abort();' not in config:
        parser.error('production LVGL assertions must abort for this host test')
    with tempfile.TemporaryDirectory(prefix='bicino-social-render-') as temporary:
        build = Path(temporary)
        (build / 'lv_conf.h').write_text(config)
        (build / 'esp_heap_caps.h').write_text(HEAP_CAPS_STUB)
        (build / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.16)
project(social_render LANGUAGES C CXX ASM)
set(CMAKE_CXX_STANDARD 17)
# Select lv_conf.h's production AMOLED PSRAM pool branch for LVGL and the test.
add_compile_definitions(BOARD_HAS_PSRAM WAVESHARE_AMOLED_175)
include_directories("{build}")
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
        for width, height, shape in DISPLAYS:
            subprocess.run([str(build / 'out/social_render'), width, height, shape],
                           check=True, timeout=120)


if __name__ == '__main__':
    main()
