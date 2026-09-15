#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::shtc3_protocol {

constexpr uint16_t kSleepCommand = 0xB098;
constexpr uint16_t kWakeCommand = 0x3517;
constexpr uint16_t kMeasureNormalPollingTemperatureFirst = 0x7866;
constexpr uint16_t kReadIdCommand = 0xEFC8;

constexpr uint8_t crc8(const uint8_t *data, std::size_t length) {
  uint8_t crc = 0xFF;
  for (std::size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x80) != 0 ? static_cast<uint8_t>((crc << 1) ^ 0x31)
                               : static_cast<uint8_t>(crc << 1);
    }
  }
  return crc;
}

constexpr bool responseWordValid(const uint8_t response[3]) {
  return response != nullptr && crc8(response, 2) == response[2];
}

constexpr uint16_t responseWord(const uint8_t response[3]) {
  return static_cast<uint16_t>((static_cast<uint16_t>(response[0]) << 8) |
                               response[1]);
}

// Sensirion specifies these fixed bits for SHTC3 identification.
constexpr bool validId(uint16_t id) { return (id & 0x083F) == 0x0807; }

constexpr float temperatureC(uint16_t raw) {
  return -45.0f + 175.0f * static_cast<float>(raw) / 65535.0f;
}

constexpr float humidityPercent(uint16_t raw) {
  return 100.0f * static_cast<float>(raw) / 65535.0f;
}

} // namespace waveshare_board::shtc3_protocol
