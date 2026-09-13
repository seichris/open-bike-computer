#include "../../lib/gui/src/worldRadioRaster.hpp"
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
  std::cout << "World Radio raster tests passed\n";
}
