#pragma once

#include <cstddef>
#include <cstdint>

inline void esp_fill_random(void *output, size_t length) {
  static uint8_t next = 1;
  auto *bytes = static_cast<uint8_t *>(output);
  for (size_t index = 0; index < length; index++) bytes[index] = next++;
}
