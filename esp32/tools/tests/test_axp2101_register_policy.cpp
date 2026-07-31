#include "../../lib/waveshare_board/axp2101_register_policy.hpp"

#include <cassert>

int main() {
  using namespace waveshare_board::axp2101::register_policy;

  static_assert(!isPowerRailControlRegister(0x7F));
  static_assert(isPowerRailControlRegister(0x80));
  static_assert(isPowerRailControlRegister(0x86));
  static_assert(!isPowerRailControlRegister(0x87));
  static_assert(!isPowerRailControlRegister(0x8F));
  static_assert(isPowerRailControlRegister(0x90));
  static_assert(isPowerRailControlRegister(0x9A));
  static_assert(!isPowerRailControlRegister(0x9B));

  assert(isWriteAllowed(0x41));
  assert(isWriteAllowed(0x49));
  assert(!isWriteAllowed(0x80));
  assert(!isWriteAllowed(0x90));
  assert(!isWriteAllowed(0x92));
  assert(!isWriteAllowed(0x9A));
  return 0;
}
