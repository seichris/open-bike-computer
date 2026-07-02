/**
 * @file qmi8658.hpp
 * @brief QMI8658 IMU helper for the Waveshare AMOLED board.
 */

#pragma once

#ifdef WAVESHARE_AMOLED_175

#include <Arduino.h>

namespace waveshare_board::imu {

enum class Orientation : uint8_t {
  Unknown,
  FaceUp,
  FaceDown,
  LeftEdgeUp,
  RightEdgeUp,
  UsbUp,
  UsbDown,
};

struct Sample {
  float accelMg[3] = {0.0f, 0.0f, 0.0f};
  float gyroDps[3] = {0.0f, 0.0f, 0.0f};
  float temperatureC = 0.0f;
  uint32_t timestamp = 0;
  uint32_t sampledAtMs = 0;
};

struct Status {
  bool present = false;
  bool configured = false;
  bool dataValid = false;
  uint8_t address = 0;
  uint8_t whoAmI = 0;
  uint8_t revision = 0;
  uint32_t sampleCount = 0;
  uint32_t failedReads = 0;
  uint32_t zeroSamples = 0;
  uint32_t lastSampleMs = 0;
  float accelMagnitudeMg = 0.0f;
  float vibrationDps = 0.0f;
  bool moving = false;
  Orientation orientation = Orientation::Unknown;
};

bool begin();
void process();
bool readSample(Sample &sample);
const Status &status();
const Sample &lastSample();
const char *orientationName(Orientation orientation);

} // namespace waveshare_board::imu

#endif // WAVESHARE_AMOLED_175
