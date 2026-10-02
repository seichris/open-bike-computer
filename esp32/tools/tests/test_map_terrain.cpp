#include "../../lib/maps/src/mapContourLabels.hpp"
#include "../../lib/maps/src/mapTerrain.hpp"
#include <cassert>
#include <vector>
int main() {
  using namespace map_terrain;
  std::vector<uint8_t> data(BYTES, 0);
  memcpy(data.data(), "FME1", 4);
  for (size_t p = 16; p < BYTES; p += 4) {
    data[p] = 100;
    data[p + 2] = 180;
  }
  uint32_t crc = 0xffffffff;
  for (size_t i = 16; i < BYTES; ++i) {
    crc ^= data[i];
    for (int b = 0; b < 8; ++b)
      crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
  }
  crc ^= 0xffffffff;
  for (int i = 0; i < 4; ++i)
    data[12 + i] = uint8_t(crc >> (i * 8));
  Grid grid;
  assert(grid.decode(data.data(), data.size()));
  Node n{};
  assert(grid.sample(64, 64, n) && n.height == 100 && n.shade == 180);
  assert(!grid.sample(-1, 0, n));
  assert(grid.sample(4096, 4096, n));
  grid.nodes[0].height = NO_DATA;
  assert(!grid.sample(64, 64, n));
  assert(grid.sample(128, 128, n));
  StreamValidator stream;
  for (uint8_t b : data)
    assert(stream.feed(&b, 1));
  assert(stream.finish());
  data.back() = 91;
  assert(!grid.decode(data.data(), data.size()));
  using namespace map_contour_labels;
  assert(segmentHits({50, 50, 20, 10}, 0, 50, 100, 50, 2));
  assert(!segmentHits({50, 50, 20, 10}, 0, 10, 100, 10, 2));
  assert(segmentHits({50, 50, 20, 10}, 50, 50, 50, 50, 2));
  std::vector<uint16_t> pixels(10000, 0);
  std::vector<uint8_t> alpha(10000, 0);
  draw({{pixels.data(), 100, 100, 100}, alpha.data(), 100}, 50, 50, -250);
  bool painted = false;
  for (auto a : alpha)
    painted |= a == 255;
  assert(painted);
}
