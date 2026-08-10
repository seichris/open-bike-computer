#pragma once

#include <cstddef>
#include <cstdint>

namespace scoped_watch_payload_policy {

inline bool hasPrefix(const uint8_t *data, size_t length, const char prefix[5]) {
  return data != nullptr && length >= 4 && data[0] == prefix[0] &&
         data[1] == prefix[1] && data[2] == prefix[2] &&
         data[3] == prefix[3];
}

inline bool isUnsignedDecimalAtMost(const uint8_t *data, size_t length,
                                    uint32_t maximum) {
  if (data == nullptr || length == 0)
    return false;
  uint32_t value = 0;
  for (size_t index = 0; index < length; ++index) {
    if (data[index] < '0' || data[index] > '9')
      return false;
    const uint32_t digit = static_cast<uint32_t>(data[index] - '0');
    if (value > (maximum - digit) / 10U)
      return false;
    value = value * 10U + digit;
  }
  return true;
}

// The Navigation characteristic historically multiplexes privileged settings,
// sound, capability, and transfer commands. A scoped Watch may use only the
// explicit ride fallbacks or the ordinary IconID|Distance|Instruction packet.
inline bool allowsNavigationPayload(const uint8_t *data, size_t length) {
  if (hasPrefix(data, length, "MAPR") || hasPrefix(data, length, "GPSP") ||
      ((length == 20 || length == 32) && hasPrefix(data, length, "WTLM"))) {
    return true;
  }
  // Ride-automation fallback is deliberately fixed-size. Prefix-only
  // acceptance would reopen this multiplexed characteristic to arbitrary
  // scoped-Watch payloads.
  if (length == 56 && hasPrefix(data, length, "RAUT")) {
    return true;
  }
  // Capability discovery is read-only and required before the Watch may use
  // the scoped transport. Accept only the exact versioned request shape; all
  // other legacy navigation-characteristic control prefixes remain denied.
  if (length == 5 && hasPrefix(data, length, "CAPS")) {
    return true;
  }
  if (data == nullptr || length == 0)
    return false;
  size_t firstPipe = length;
  size_t secondPipe = length;
  for (size_t index = 0; index < length; ++index) {
    if (data[index] != '|')
      continue;
    if (firstPipe == length) {
      firstPipe = index;
    } else {
      secondPipe = index;
      break;
    }
  }
  return firstPipe < length && secondPipe < length &&
         isUnsignedDecimalAtMost(data, firstPipe, 255) &&
         isUnsignedDecimalAtMost(data + firstPipe + 1,
                                 secondPipe - firstPipe - 1, 2147483647U);
}

} // namespace scoped_watch_payload_policy
