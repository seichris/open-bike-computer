#pragma once
#include "mapSurface.hpp"
#include "map_projection.hpp"
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace map_terrain {
constexpr size_t SIDE = 33, STEP = 128, BYTES = 16 + SIDE * SIDE * 4;
constexpr int16_t NO_DATA = -32768;
constexpr uint32_t HILLSHADE = 1u << 14, TINT = 1u << 15, SLOPE = 1u << 16,
                   HEIGHT = 1u << 17;
constexpr uint32_t MASK = HILLSHADE | TINT | SLOPE | HEIGHT;
struct Node {
  int16_t height;
  uint8_t shade, slope;
};
static_assert(sizeof(Node) == 4, "terrain node wire size");
// Constant-space streaming validation, including semantic and CRC checks.
class StreamValidator {
  size_t count_ = 0;
  uint32_t crc_ = 0xffffffffu, expected_ = 0;
  std::array<uint8_t, 16> header_{};
  std::array<uint8_t, 4> node_{};
  bool bad_ = false;

public:
  bool feed(const uint8_t *data, size_t length) {
    if (bad_ || (!data && length) || length > BYTES - count_)
      return !(bad_ = true);
    for (size_t i = 0; i < length; ++i, ++count_) {
      const uint8_t v = data[i];
      if (count_ < 16) {
        header_[count_] = v;
        if (count_ == 15) {
          if (memcmp(header_.data(), "FME1", 4))
            return !(bad_ = true);
          const auto u32 = [&](size_t p) {
            return uint32_t(header_[p]) | uint32_t(header_[p + 1]) << 8 |
                   uint32_t(header_[p + 2]) << 16 |
                   uint32_t(header_[p + 3]) << 24;
          };
          const int32_t x = int32_t(u32(4)), y = int32_t(u32(8));
          if (x < -4892 || x > 4891 || y < -4892 || y > 4891)
            return !(bad_ = true);
          expected_ = u32(12);
        }
      } else {
        crc_ ^= v;
        for (int bit = 0; bit < 8; ++bit)
          crc_ = (crc_ >> 1) ^ (0xedb88320u & (0u - (crc_ & 1u)));
        node_[(count_ - 16) % 4] = v;
        if ((count_ - 16) % 4 == 3) {
          const int16_t h =
              int16_t(uint16_t(node_[0]) | uint16_t(node_[1]) << 8);
          if (h == NO_DATA ? node_[2] || node_[3]
                           : (h < -12000 || h > 10000 || node_[3] > 90))
            return !(bad_ = true);
        }
      }
    }
    return true;
  }
  bool finish() {
    return !bad_ && count_ == BYTES && (crc_ ^ 0xffffffffu) == expected_;
  }
  bool failed() const { return bad_; }
};

struct Grid {
  int32_t bx = 0, by = 0;
  std::array<Node, SIDE * SIDE> nodes{};
  bool decode(const uint8_t *data, size_t size) {
    StreamValidator check;
    if (!check.feed(data, size) || !check.finish())
      return false;
    auto s32 = [&](int p) {
      return int32_t(uint32_t(data[p]) | uint32_t(data[p + 1]) << 8 |
                     uint32_t(data[p + 2]) << 16 | uint32_t(data[p + 3]) << 24);
    };
    bx = s32(4);
    by = s32(8);
    for (size_t i = 0; i < nodes.size(); ++i) {
      const auto p = data + 16 + i * 4;
      nodes[i] = {int16_t(uint16_t(p[0]) | uint16_t(p[1]) << 8), p[2], p[3]};
    }
    return true;
  }
  bool sample(double worldX, double worldY, Node &out) const {
    const double x = (worldX - double(bx) * 4096) / STEP,
                 y = (worldY - double(by) * 4096) / STEP;
    if (!(x >= 0 && x <= 32 && y >= 0 && y <= 32))
      return false;
    const int ix = std::min(31, int(x)), iy = std::min(31, int(y));
    const float fx = float(x - ix), fy = float(y - iy);
    const Node ns[] = {nodes[iy * SIDE + ix], nodes[iy * SIDE + ix + 1],
                       nodes[(iy + 1) * SIDE + ix],
                       nodes[(iy + 1) * SIDE + ix + 1]};
    const float ws[] = {(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy,
                        fx * fy};
    float height = 0, shade = 0, slope = 0;
    for (int i = 0; i < 4; ++i) {
      if (ws[i] > 0 && ns[i].height == NO_DATA)
        return false;
      height += ws[i] * ns[i].height;
      shade += ws[i] * ns[i].shade;
      slope += ws[i] * ns[i].slope;
    }
    out = {int16_t(std::lround(height)), uint8_t(std::lround(shade)),
           uint8_t(std::lround(slope))};
    return true;
  }
};
inline uint16_t color(Node n, uint32_t mode, uint16_t base) {
  int r = (base >> 11) * 255 / 31, g = ((base >> 5) & 63) * 255 / 63,
      b = (base & 31) * 255 / 31;
  if (mode & (TINT | SLOPE | HEIGHT)) {
    float t = mode & SLOPE ? std::min(1.f, n.slope / 45.f)
                           : std::clamp((n.height + 200.f) / 3200.f, 0.f, 1.f);
    int tr = int(105 + 130 * t), tg = int(180 - 55 * t), tb = int(110 - 25 * t);
    r = (r + tr * 2) / 3;
    g = (g + tg * 2) / 3;
    b = (b + tb * 2) / 3;
  }
  if (mode & (HILLSHADE | HEIGHT)) {
    const int shade = 192 + n.shade / 4;
    r = r * shade / 255;
    g = g * shade / 255;
    b = b * shade / 255;
  }
  return uint16_t((r * 31 / 255) << 11 | (g * 63 / 255) << 5 | b * 31 / 255);
}
} // namespace map_terrain
