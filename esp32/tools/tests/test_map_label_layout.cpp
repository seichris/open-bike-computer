#include "../../lib/maps/src/mapLabelLayout.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
  using map_label_layout::Bounds;
  using map_label_layout::Option;

  std::vector<Option> options = {
      {1, 10, 0, 0, 0, 100, 60, 60, 0, 80, 14},
      {2, 11, 0, 1, 1, 100, 64, 60, 0, 80, 14},
      {3, 12, 0, 2, 2, 90, 160, 60, 0, 50, 14},
      {4, 10, 1, 0, 4, 120, 160, 120, 0, 50, 14},
  };
  map_label_layout::Diagnostics diagnostics;
  const auto balanced =
      map_label_layout::place(options, Bounds{240, 180}, 2, {}, &diagnostics);
  assert(balanced.size() == 2);
  assert(balanced[0].option.labelKey == 1);
  assert(balanced[1].option.labelKey == 3);
  assert(diagnostics.gathered == 4);
  assert(diagnostics.accepted == 2);
  assert(diagnostics.collisionTested == 3);
  assert(diagnostics.collisionRejected == 1);
  assert(diagnostics.duplicateRejected == 1);

  const auto off = map_label_layout::place(options, Bounds{240, 180}, 0);
  assert(off.empty());

  std::vector<Option> rotated = {
      {1, 1, 0, 0, 0, 100, 100, 100, 0.785398F, 90, 18},
      {2, 2, 0, 1, 0, 90, 100, 100, -0.785398F, 90, 18},
  };
  assert(map_label_layout::place(rotated, Bounds{220, 220}, 3).size() == 1);

  std::vector<Option> alternatives = {
      {8, 8, 0, 0, 0, 100, 10, 10, 0, 80, 14}, // outside
      {8, 8, 0, 0, 0, 90, 100, 100, 0, 80, 14}, // fallback
  };
  const auto selected =
      map_label_layout::place(alternatives, Bounds{220, 220}, 2);
  assert(selected.size() == 1);
  assert(selected[0].option.centerX == 100);

  MapLabelLayoutVector<Option> plentiful;
  for (uint32_t index = 0; index < 100; index++) {
    plentiful.push_back({index + 1, static_cast<uint16_t>(index + 1), 0,
                         static_cast<uint16_t>(index), 0, 100,
                         20.0F + index * 20.0F, 50, 0, 5, 5});
  }
  map_label_layout::Diagnostics capacityDiagnostics;
  const auto capped = map_label_layout::place(
      plentiful, Bounds{2040, 100}, 3, {}, &capacityDiagnostics);
  assert(capped.size() == 96);
  assert(capacityDiagnostics.capacityRejected == 4);

  std::cout << "map label layout tests passed\n";
  return 0;
}
