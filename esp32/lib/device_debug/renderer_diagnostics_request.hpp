#pragma once

#include "../renderer_diagnostics/renderer_diagnostics_policy.hpp"

#include <cstddef>
#include <cstdint>

namespace device_debug {

constexpr size_t kRendererWindowBodyMaximumBytes = 1024;

struct RendererRunRequest {
  uint32_t requestId = 0;
  renderer_diagnostics::RunIdentity identity{};
  renderer_tuning::Profile profile = renderer_tuning::Profile::Current;
};

inline bool validRendererIdentityText(const char *value, size_t maximumBytes) {
  if (value == nullptr || maximumBytes == 0)
    return false;
  size_t length = 0;
  for (; value[length] != '\0'; ++length) {
    if (length >= maximumBytes)
      return false;
    const char character = value[length];
    const bool allowed =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '-' ||
        character == '_' || character == '.' || character == ':';
    if (!allowed)
      return false;
  }
  return length != 0;
}

inline bool validLowercaseSha256(const char *value) {
  if (value == nullptr)
    return false;
  for (size_t index = 0; index < 64; ++index) {
    const char character = value[index];
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f')))
      return false;
  }
  return value[64] == '\0';
}

inline bool validRendererRouteMode(const char *value) {
  if (value == nullptr)
    return false;
  static constexpr const char *kModes[] = {
      "ios-fixture-1hz",
      "ordinary-ble-1hz",
  };
  for (const char *mode : kModes) {
    size_t index = 0;
    while (value[index] != '\0' && value[index] == mode[index])
      ++index;
    if (value[index] == '\0' && mode[index] == '\0')
      return true;
  }
  return false;
}

} // namespace device_debug
