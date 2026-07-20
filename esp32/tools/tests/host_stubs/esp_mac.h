#pragma once

#include <cstdint>
#include <cstddef>

using esp_err_t = int;
constexpr esp_err_t ESP_OK = 0;

inline esp_err_t esp_efuse_mac_get_default(uint8_t mac[6]) {
  if (mac == nullptr) return -1;
  const uint8_t fixed[6] = {0x02, 0x00, 0x00, 0x12, 0x34, 0x56};
  for (size_t index = 0; index < 6; index++) mac[index] = fixed[index];
  return ESP_OK;
}
