#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(WAVESHARE_EPAPER_397)

#include <Arduino.h>

namespace waveshare_board::shtc3 {

struct Status {
  bool present = false;
  bool identified = false;
  bool dataValid = false;
  uint16_t id = 0;
  float temperatureC = 0.0f;
  float humidityPercent = 0.0f;
  uint32_t sampleCount = 0;
  uint32_t failedReads = 0;
  uint32_t crcFailures = 0;
  uint32_t lastSampleMs = 0;
};

bool begin();
void process();
bool readSample();
const Status &status();

} // namespace waveshare_board::shtc3

#endif
