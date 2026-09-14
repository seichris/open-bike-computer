#pragma once

#include <cstddef>
#include <cstdint>

namespace world_radio_map {

inline constexpr int16_t WIDTH = 1024;
inline constexpr int16_t HEIGHT = 512;

// Decode directly into the LVGL RGB565 canvas (including padded strides).
// Packet high bit selects a palette-index run; low seven bits + 1 are length.
inline bool decode(const uint8_t *packets, std::size_t packetBytes,
                   const uint16_t (&palette)[256], uint16_t *destination,
                   std::size_t capacityPixels, std::size_t width,
                   std::size_t height, std::size_t stridePixels) {
  if (packets == nullptr || destination == nullptr || width == 0 || height == 0 ||
      stridePixels < width || height > capacityPixels / stridePixels) {
    return false;
  }
  const std::size_t pixelCount = width * height;
  std::size_t input = 0;
  std::size_t output = 0;
  while (input < packetBytes && output < pixelCount) {
    const uint8_t control = packets[input++];
    const std::size_t count = (control & 0x7f) + 1;
    const bool repeat = (control & 0x80) != 0;
    const std::size_t payloadBytes = repeat ? 1 : count;
    if (count > pixelCount - output || payloadBytes > packetBytes - input) {
      return false;
    }
    for (std::size_t i = 0; i < count; ++i, ++output) {
      destination[(output / width) * stridePixels + output % width] =
          palette[packets[input + (repeat ? 0 : i)]];
    }
    input += payloadBytes;
  }
  return input == packetBytes && output == pixelCount;
}

bool render(uint16_t *destination, std::size_t capacityPixels,
            std::size_t stridePixels);

} // namespace world_radio_map
