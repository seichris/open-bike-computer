#pragma once

#include "mapLabelBlock.hpp"

#include <cstdint>

namespace map_label_selection {

struct Selection {
  const map_label_block::Variant *lines[2] = {nullptr, nullptr};
  uint8_t count = 0;
};

inline const map_label_block::Variant *
variantOfKind(const map_label_block::RoadLabel &label, uint8_t kind) {
  for (const auto &variant : label.variants) {
    if (variant.kind == kind)
      return &variant;
  }
  return nullptr;
}

// Modes: 0=Local, 1=Preferred, 2=Local + Preferred. The fallback order is
// deliberately centralized here so firmware behavior remains identical to the
// documented pack semantics.
inline Selection select(const map_label_block::RoadLabel &label,
                        uint8_t mode) {
  const auto *local = variantOfKind(label, 0);
  const auto *preferred = variantOfKind(label, 1);
  const auto *international = variantOfKind(label, 2);
  const auto *reference = variantOfKind(label, 3);
  Selection result;
  if (mode == 1) {
    result.lines[0] = preferred != nullptr ? preferred
                      : local != nullptr   ? local
                      : international != nullptr ? international
                                                 : reference;
  } else {
    result.lines[0] = local != nullptr ? local
                      : preferred != nullptr ? preferred
                      : international != nullptr ? international
                                                 : reference;
  }
  result.count = result.lines[0] != nullptr ? 1 : 0;
  if (mode == 2 && result.lines[0] != nullptr) {
    const auto *second = preferred != nullptr ? preferred : international;
    if (second != nullptr && second->stringId != result.lines[0]->stringId) {
      result.lines[1] = second;
      result.count = 2;
    }
  }
  return result;
}

} // namespace map_label_selection
