#include "../../lib/gui/src/worldRadioFlags.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
int main() {
  using namespace world_radio_flags;
  for (const char *code : {"FR", "US", "CN", "BR", "ES", "JP", "ZA"}) assert(find(code));
  assert(!find(nullptr) && !find("") && !find("ZZ") && !find("fr") && !find("USA"));
  assert(std::memcmp(find("FR"), find("US"), WIDTH * HEIGHT * sizeof(uint16_t)) != 0);
  std::cout << "World Radio flag tests passed\n";
}
