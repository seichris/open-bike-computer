#include "../../lib/maps/src/mapLabelSelection.hpp"

#include <cassert>
#include <iostream>

namespace {

map_label_block::Variant variant(uint8_t kind, uint16_t stringId) {
  map_label_block::Variant value;
  value.kind = kind;
  value.stringId = stringId;
  return value;
}

} // namespace

int main() {
  map_label_block::RoadLabel complete;
  complete.variants = {variant(0, 10), variant(1, 11), variant(2, 12),
                       variant(3, 13)};
  auto selected = map_label_selection::select(complete, 0);
  assert(selected.count == 1 && selected.lines[0]->stringId == 10);
  selected = map_label_selection::select(complete, 1);
  assert(selected.count == 1 && selected.lines[0]->stringId == 11);
  selected = map_label_selection::select(complete, 2);
  assert(selected.count == 2 && selected.lines[0]->stringId == 10 &&
         selected.lines[1]->stringId == 11);

  map_label_block::RoadLabel preferredMissing;
  preferredMissing.variants = {variant(0, 20), variant(2, 21),
                               variant(3, 22)};
  selected = map_label_selection::select(preferredMissing, 1);
  assert(selected.count == 1 && selected.lines[0]->stringId == 20);
  selected = map_label_selection::select(preferredMissing, 2);
  assert(selected.count == 2 && selected.lines[0]->stringId == 20 &&
         selected.lines[1]->stringId == 21);

  map_label_block::RoadLabel localMissing;
  localMissing.variants = {variant(2, 30), variant(3, 31)};
  selected = map_label_selection::select(localMissing, 1);
  assert(selected.count == 1 && selected.lines[0]->stringId == 30);

  map_label_block::RoadLabel duplicate;
  duplicate.variants = {variant(0, 40), variant(1, 40)};
  selected = map_label_selection::select(duplicate, 2);
  assert(selected.count == 1 && selected.lines[0]->stringId == 40);

  std::cout << "map label selection tests passed\n";
  return 0;
}
