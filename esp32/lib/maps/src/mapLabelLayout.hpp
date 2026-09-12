#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T>
using MapLabelLayoutVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapLabelLayoutVector = std::vector<T>;
#endif

namespace map_label_layout {

struct Option {
  uint32_t labelKey = 0;
  uint16_t repeatGroup = 0;
  uint16_t blockOrder = 0;
  uint16_t labelOrder = 0;
  uint8_t rank = 0;
  uint8_t quality = 0;
  float centerX = 0;
  float centerY = 0;
  float angleRadians = 0;
  float width = 0;
  float height = 0;
};

struct Placement {
  Option option;
};

struct Bounds {
  float width = 0;
  float height = 0;
};

struct ReservedRegion {
  float centerX = 0;
  float centerY = 0;
  float width = 0;
  float height = 0;
};

struct Diagnostics {
  size_t gathered = 0;
  size_t invalidOrDensityRejected = 0;
  size_t duplicateRejected = 0;
  size_t outsideScreenRejected = 0;
  size_t collisionTested = 0;
  size_t collisionRejected = 0;
  size_t capacityRejected = 0;
  size_t accepted = 0;
};

// Density: 0=off, 1=sparse, 2=balanced, 3=dense. The result is stable for
// identical inputs and shares one collision/repetition space across all blocks.
MapLabelLayoutVector<Placement>
place(MapLabelLayoutVector<Option> options, Bounds screen, uint8_t density,
      const MapLabelLayoutVector<ReservedRegion> &reserved = {},
      Diagnostics *diagnostics = nullptr);

} // namespace map_label_layout
