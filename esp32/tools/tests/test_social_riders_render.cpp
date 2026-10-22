// Real LVGL/software renderer and production badges, built against lv_conf.h's
// production AMOLED PSRAM pool branch with a fragmented resident-UI budget. This
// is a host allocation regression, not a full firmware simulation: the host is
// 64-bit, so LVGL objects and TLSF headers are larger than on the device.
#include "social_riders_view.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if !defined(LV_MEM_POOL_ALLOC)
#error "The render test must use the production AMOLED PSRAM pool branch"
#endif
static_assert(LV_MEM_SIZE == 192 * 1024U, "production AMOLED LVGL pool size");

// Counted by the host heap_caps_aligned_alloc stand-in (the PSRAM pool source).
extern "C" {
unsigned bicino_host_psram_pool_allocations = 0;
}

static unsigned flushes = 0;

int main(int argc, char **argv) {
  // Panel width, height and shape: 466 466 round (1.75") or 410 502 rect (2.06").
  const int width = argc > 1 ? std::atoi(argv[1]) : 466;
  const int height = argc > 2 ? std::atoi(argv[2]) : 466;
  const bool round = argc > 3 ? std::strcmp(argv[3], "rect") != 0 : true;
  assert(width > 0 && height > 0);
  lv_init();
  assert(bicino_host_psram_pool_allocations == 1);
  lv_mem_monitor_t initial{};
  lv_mem_monitor(&initial);
  assert(initial.total_size > 180u * 1024 && initial.total_size <= LV_MEM_SIZE);
  // Other firmware pages stay resident while the map is visible. Model them as
  // many small long-lived allocations separated by freed gaps, like the
  // incident pool (87,216 live bytes in 2,323 TLSF blocks), rather than one
  // contiguous block that cannot fragment.
  std::vector<void *> resident, gaps;
  size_t residentBytes = 0;
  for (unsigned i = 0; residentBytes < 64 * 1024; ++i) {
    const size_t size = 24 + (i * 37) % 97;
    void *gap = lv_malloc(16 + i % 17);
    void *block = lv_malloc(size);
    assert(gap && block);
    gaps.push_back(gap);
    resident.push_back(block);
    residentBytes += size;
  }
  for (void *gap : gaps) lv_free(gap);
  auto *display = lv_display_create(width, height);
  std::vector<uint16_t> pixels(size_t(width) * height);
  lv_display_set_buffers(display, pixels.data(), nullptr, pixels.size() * 2,
                         LV_DISPLAY_RENDER_MODE_FULL);
  lv_display_set_flush_cb(display, [](lv_display_t *d, const lv_area_t *, uint8_t *) {
    ++flushes;
    lv_display_flush_ready(d);
  });
  auto *map = lv_image_create(lv_screen_active());
  lv_image_dsc_t image{};
  image.header.magic = LV_IMAGE_HEADER_MAGIC;
  image.header.cf = LV_COLOR_FORMAT_RGB565;
  image.header.w = width; image.header.h = height; image.header.stride = width * 2;
  std::vector<uint16_t> mapPixels(size_t(width) * height, 0x3456);
  image.data_size = mapPixels.size() * 2;
  image.data = reinterpret_cast<const uint8_t *>(mapPixels.data());
  lv_image_set_src(map, &image);
  social_riders::Rider rider{};
  rider.present = true;
  std::snprintf(rider.initials, sizeof(rider.initials), "NT");
  uint32_t baseline = 0;
  uint32_t smallestFreeBlock = UINT32_MAX;
  lv_mem_monitor_t memory{};
  constexpr uint16_t scales[] = {100, 125, 150, 200, 250, 300};
  for (unsigned frame = 0; frame < 600; ++frame) {
    social_riders::beginFrame();
    // Pan across the viewport; alternate portraits/initials, stale/fresh,
    // clusters, rim distance labels, covered map and no-map orientation, and
    // resize every badge in place through each friend-marker size twice.
    const uint16_t scale = scales[(frame / 50) % 6];
    const auto badge = social_riders::badgeGeometry(scale);
    for (size_t i = 0; i < social_riders::CAPACITY; ++i) {
      rider.imageReady = (i + frame / 30) % 2 == 0;
      rider.imageHash[0] = static_cast<uint8_t>(i + 1);
      rider.image.fill(static_cast<uint8_t>(i * 30));
      rider.age = frame % 60 < 30 ? 0 : 20;
      const auto point = social_riders::edge(
          std::sin(i * 0.785398 + frame * 0.02),
          std::cos(i * 0.785398 + frame * 0.02), width, height, round,
          badge.halfWidth(), badge.halfHeight());
      social_riders::draw(i, lv_screen_active(), point.x, point.y, rider,
                          frame % 3 != 0, 800 + frame % 50, 0, scale);
      if (frame % 10 == 0) social_riders::addClusterMember(i);
    }
    if (frame % 2) social_riders::showFallbackOrientation(lv_screen_active(), frame % 4 == 1);
    social_riders::endFrame();
    lv_obj_set_pos(map, -(frame % 16), -(frame % 12));
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(display);
    lv_mem_monitor(&memory);
    smallestFreeBlock = std::min(smallestFreeBlock, uint32_t(memory.free_biggest_size));
    assert(memory.free_biggest_size >= 32 * 1024);
    assert(lv_mem_test() == LV_RESULT_OK);
    if (frame == 100) baseline = memory.total_size - memory.free_size;
    if (frame > 100) assert(memory.total_size - memory.free_size <= baseline + 2048);
  }
  assert(flushes >= 600);
  // The free blocks above are sampled between frames, after temporary draw,
  // glyph and layer buffers are released. LVGL's high-water mark also covers
  // the moments inside each refresh (and the resident setup), so it bounds the
  // headroom from below. Allocation sizes are deterministic on 64-bit hosts;
  // a peak-use regression of more than ~28 KiB fails here before the device
  // (with smaller 32-bit objects) runs out.
  const uint32_t peakFree = uint32_t(memory.total_size - memory.max_used);
  assert(peakFree >= 48 * 1024);
  social_riders::hideView();
  lv_refr_now(display);
  lv_obj_delete(map);
  lv_display_delete(display);
  for (void *block : resident) lv_free(block);
  std::printf("%dx%d %s: %u full refreshes with eight riders: stable usage; "
              "minimum largest free block between frames %u bytes; "
              "minimum free at peak use %u bytes\n",
              width, height, round ? "round" : "rect", flushes, smallestFreeBlock, peakFree);
}
