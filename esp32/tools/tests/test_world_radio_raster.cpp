#include "../../lib/gui/src/worldRadioRaster.hpp"
#include "../../lib/gui/src/worldRadioViewport.hpp"
#include <chrono>
#include <cassert>
#include <vector>
#include <iostream>

int main() {
  constexpr int worldWidth = 1024, worldHeight = 512, sourceStride = 1028;
  std::vector<uint16_t> world(sourceStride * worldHeight, 0xffff);
  for (int y = 0; y < worldHeight; ++y)
    for (int x = 0; x < worldWidth; ++x) world[y * sourceStride + x] = (y * 13 + x * 7) & 0xffff;
  for (int width : {410, 466}) {
    const int height = width == 466 ? 466 : 502;
    const int stride = width + 4;
    std::vector<uint16_t> output(stride * height, 0xffff);
    for (int cameraX : {0, -1, -2, -1023, -2047}) {
      for (int cameraY : {0, -1, height - 1024}) {
        world_radio_raster::render(world.data(), worldWidth, sourceStride,
            output.data(), width, height, stride, cameraX, cameraY);
        for (int y = 0; y < height; ++y) {
          for (int x = 0; x < width; ++x)
            assert(output[y * stride + x] == world[((y-cameraY)/2) * sourceStride + ((x-cameraX)/2) % worldWidth]);
          assert(output[y * stride + width] == 0xffff);
        }
      }
    }
  }
  // Synthetic drag replay: repeated touch samples used to trigger a complete
  // raster composition even when the pointer/camera did not move. Compare final
  // pixels and composition counts, not machine-dependent timing thresholds.
  constexpr int width = 466, height = 466;
  std::vector<uint16_t> baseline(width * height), filtered(width * height);
  world_radio_viewport::Camera before, after;
  before.configure(width, height, 2048, 1024);
  after.configure(width, height, 2048, 1024);
  world_radio_viewport::DragSession gesture;
  gesture.begin(100, 100);
  unsigned baselineRenders = 0, filteredRenders = 0;
  auto started = std::chrono::steady_clock::now();
  int lastX = 100;
  for (int x = 100; x <= 160; ++x) {
    for (int repeat = 0; repeat < 10; ++repeat) {
      before.drag(x - lastX, 0);
      lastX = x;
      world_radio_raster::render(world.data(), worldWidth, sourceStride,
          baseline.data(), width, height, width, before.x(), before.y());
      ++baselineRenders;
    }
  }
  const auto baselineUs = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - started).count();
  started = std::chrono::steady_clock::now();
  for (int x = 100; x <= 160; ++x) {
    for (int repeat = 0; repeat < 10; ++repeat) {
      if (!gesture.sample(x, 100, after)) continue;
      world_radio_raster::render(world.data(), worldWidth, sourceStride,
          filtered.data(), width, height, width, after.x(), after.y());
      ++filteredRenders;
    }
  }
  const auto filteredUs = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - started).count();
  assert(baseline == filtered);
  assert(baselineRenders == 610 && filteredRenders == 51);
  std::cout << "Synthetic drag replay compositions=" << baselineRenders << "->"
            << filteredRenders << " host_us=" << baselineUs << "->" << filteredUs << '\n';
  std::cout << "World Radio raster tests passed\n";
}
