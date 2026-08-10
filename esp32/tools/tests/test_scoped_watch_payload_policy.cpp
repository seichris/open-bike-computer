#include "../../lib/ble_navigation/scoped_watch_payload_policy.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

static bool allowed(const std::string &value) {
  return scoped_watch_payload_policy::allowsNavigationPayload(
      reinterpret_cast<const uint8_t *>(value.data()), value.size());
}

int main() {
  assert(allowed("3|120|Turn right"));
  assert(allowed("0|0|"));
  assert(allowed("MAPR\x01\x02"));
  assert(allowed("GPSP\x01\x02"));
  assert(allowed("WTLM\x01\x02"));
  assert(allowed("CAPS\x0a"));
  assert(!allowed("MSET\x01\x02"));
  assert(!allowed("MTRN|erase"));
  assert(!allowed("DTRN|firmware"));
  assert(!allowed("SNDP|5|100"));
  assert(!allowed("CAPQ|10"));
  assert(!allowed("CAPS"));
  std::string oversizedCapability("CAPS\x0a", 5);
  oversizedCapability.push_back('\0');
  assert(!allowed(oversizedCapability));
  assert(!allowed("DLST|catalog"));
  assert(!allowed("abc|120|Turn"));
  assert(!allowed("3|-1|Turn"));
  assert(!allowed("256|1|Turn"));
  assert(!allowed("3|2147483648|Turn"));
  assert(!allowed("999999999999999999999|1|Turn"));
  assert(!allowed("3|120"));
  assert(!allowed(""));
  std::cout << "scoped Watch payload policy tests passed\n";
  return 0;
}
