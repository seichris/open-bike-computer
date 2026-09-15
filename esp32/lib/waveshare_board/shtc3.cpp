#include "shtc3.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(WAVESHARE_EPAPER_397)

#include "i2c_bus.hpp"
#include "shtc3_protocol.hpp"
#include "waveshare_board.hpp"

namespace waveshare_board::shtc3 {
namespace {

constexpr uint32_t kSampleIntervalMs = 10000;
constexpr uint32_t kWakeDelayMs = 1;
constexpr uint32_t kMeasurementDelayMs = 13;
Status sensorStatus;
uint32_t lastAttemptMs = 0;

bool command(uint16_t value, const char *label, uint8_t attempts = 3) {
  return i2c::writeCommand16(SHTC3_ADDR, value, label, attempts);
}

void returnToSleep() {
  if (!command(shtc3_protocol::kSleepCommand, "SHTC3 sleep", 2)) {
    ++sensorStatus.failedReads;
  }
}

} // namespace

bool begin() {
  sensorStatus = {};
  lastAttemptMs = 0;
  sensorStatus.present = i2c::probe(SHTC3_ADDR, "SHTC3", 2);
  if (!sensorStatus.present ||
      !command(shtc3_protocol::kWakeCommand, "SHTC3 wake")) {
    return false;
  }
  delay(kWakeDelayMs);

  uint8_t response[3] = {};
  const bool readOk =
      command(shtc3_protocol::kReadIdCommand, "SHTC3 read ID") &&
      i2c::readBytes(SHTC3_ADDR, response, sizeof(response),
                     "SHTC3 ID response", 3);
  if (readOk && shtc3_protocol::responseWordValid(response)) {
    sensorStatus.id = shtc3_protocol::responseWord(response);
    sensorStatus.identified = shtc3_protocol::validId(sensorStatus.id);
  } else if (readOk) {
    ++sensorStatus.crcFailures;
  }
  returnToSleep();
  Serial.printf("SHTC3: present=%d identified=%d id=0x%04X crcFailures=%lu\n",
                sensorStatus.present, sensorStatus.identified,
                sensorStatus.id,
                static_cast<unsigned long>(sensorStatus.crcFailures));
  return sensorStatus.identified;
}

bool readSample() {
  lastAttemptMs = millis();
  if (!sensorStatus.identified) {
    return false;
  }
  if (!command(shtc3_protocol::kWakeCommand, "SHTC3 wake")) {
    ++sensorStatus.failedReads;
    return false;
  }
  delay(kWakeDelayMs);
  if (!command(shtc3_protocol::kMeasureNormalPollingTemperatureFirst,
               "SHTC3 measure")) {
    ++sensorStatus.failedReads;
    returnToSleep();
    return false;
  }
  delay(kMeasurementDelayMs);

  uint8_t response[6] = {};
  const bool readOk = i2c::readBytes(SHTC3_ADDR, response, sizeof(response),
                                     "SHTC3 measurement", 3);
  returnToSleep();
  if (!readOk) {
    ++sensorStatus.failedReads;
    sensorStatus.dataValid = false;
    return false;
  }
  if (!shtc3_protocol::responseWordValid(response) ||
      !shtc3_protocol::responseWordValid(response + 3)) {
    ++sensorStatus.crcFailures;
    sensorStatus.dataValid = false;
    return false;
  }

  sensorStatus.temperatureC = shtc3_protocol::temperatureC(
      shtc3_protocol::responseWord(response));
  sensorStatus.humidityPercent = shtc3_protocol::humidityPercent(
      shtc3_protocol::responseWord(response + 3));
  sensorStatus.dataValid = true;
  sensorStatus.lastSampleMs = millis();
  ++sensorStatus.sampleCount;
  return true;
}

void process() {
  const uint32_t now = millis();
  if (lastAttemptMs != 0 && now - lastAttemptMs < kSampleIntervalMs) {
    return;
  }
  (void)readSample();
}

const Status &status() { return sensorStatus; }

} // namespace waveshare_board::shtc3

#endif
