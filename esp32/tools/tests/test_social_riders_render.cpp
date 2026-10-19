// Real LVGL/software renderer and production badges, with a bounded resident-UI
// budget. This is a host allocation regression, not a full firmware simulation.
#include "social_riders_view.hpp"
#include <cassert>
#include <cstdio>
#include <vector>

static unsigned flushes = 0;

int main() {
  lv_init();
  // Other firmware pages remain resident while the map is visible. Reserve
  // 64 KiB for those objects/styles; the incident pool held 87,216 live bytes
  // plus 2,323 TLSF block headers before the failing glyph allocation.
  auto *resident = lv_malloc(64 * 1024);
  assert(resident);
  auto *display = lv_display_create(466, 466);
  std::vector<uint16_t> pixels(466 * 466);
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
  image.header.w = 466; image.header.h = 466; image.header.stride = 466 * 2;
  std::vector<uint16_t> mapPixels(466 * 466, 0x3456);
  image.data_size = mapPixels.size() * 2;
  image.data = reinterpret_cast<const uint8_t *>(mapPixels.data());
  lv_image_set_src(map, &image);
  social_riders::Rider rider{};
  rider.present = true;
  std::snprintf(rider.initials, sizeof(rider.initials), "NT");
  uint32_t baseline = 0;
  uint32_t smallestFreeBlock = UINT32_MAX;
  for (unsigned frame = 0; frame < 600; ++frame) {
    social_riders::beginFrame();
    // Pan across the viewport; alternate portraits/initials, stale/fresh,
    // clusters, rim distance labels, covered map and no-map orientation.
    for (size_t i = 0; i < social_riders::CAPACITY; ++i) {
      rider.imageReady = (i + frame / 30) % 2 == 0;
      rider.imageHash[0] = static_cast<uint8_t>(i + 1);
      rider.image.fill(static_cast<uint8_t>(i * 30));
      rider.age = frame % 60 < 30 ? 0 : 20;
      const auto point = social_riders::edge(
          std::sin(i * 0.785398 + frame * 0.02),
          std::cos(i * 0.785398 + frame * 0.02), 466, 466, true);
      social_riders::draw(i, lv_screen_active(), point.x, point.y, rider,
                          frame % 3 != 0, 800 + frame % 50, 0);
      if (frame % 10 == 0) social_riders::addClusterMember(i);
    }
    if (frame % 2) social_riders::showFallbackOrientation(lv_screen_active(), frame % 4 == 1);
    social_riders::endFrame();
    lv_obj_set_pos(map, -(frame % 16), -(frame % 12));
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(display);
    lv_mem_monitor_t memory{};
    lv_mem_monitor(&memory);
    smallestFreeBlock = std::min(smallestFreeBlock, uint32_t(memory.free_biggest_size));
    assert(memory.free_biggest_size >= 32 * 1024);
    assert(lv_mem_test() == LV_RESULT_OK);
    if (frame == 100) baseline = memory.total_size - memory.free_size;
    if (frame > 100) assert(memory.total_size - memory.free_size <= baseline + 2048);
  }
  assert(flushes >= 600);
  social_riders::hideView();
  lv_refr_now(display);
  lv_obj_delete(map);
  lv_display_delete(display);
  lv_free(resident);
  std::printf("%u full refreshes with eight riders: stable usage; minimum largest free block %u bytes\n",
              flushes, smallestFreeBlock);
}
