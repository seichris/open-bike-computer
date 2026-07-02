/**
 * @file qmi8658.cpp
 * @brief QMI8658 IMU helper for the Waveshare AMOLED board.
 */

#include "qmi8658.hpp"

#ifdef WAVESHARE_AMOLED_175

#include "i2c_bus.hpp"
#include "waveshare_board.hpp"
#include <math.h>

namespace waveshare_board::imu {

namespace {

constexpr uint8_t REG_WHO_AM_I = 0x00;
constexpr uint8_t REG_REVISION = 0x01;
constexpr uint8_t REG_CTRL1 = 0x02;
constexpr uint8_t REG_CTRL2 = 0x03;
constexpr uint8_t REG_CTRL3 = 0x04;
constexpr uint8_t REG_CTRL5 = 0x06;
constexpr uint8_t REG_CTRL7 = 0x08;
constexpr uint8_t REG_STATUS_INT = 0x2D;
constexpr uint8_t REG_STATUS0 = 0x2E;
constexpr uint8_t REG_STATUS1 = 0x2F;
constexpr uint8_t REG_TIMESTAMP_L = 0x30;
constexpr uint8_t REG_AX_L = 0x35;
constexpr uint8_t REG_GX_L = 0x3B;
constexpr uint8_t REG_RST_RESULT = 0x4D;
constexpr uint8_t REG_RESET = 0x60;

constexpr uint8_t EXPECTED_WHO_AM_I = 0x05;
constexpr uint8_t RESET_VALUE = 0xB0;
constexpr uint8_t RST_RESULT_OK = 0x80;
constexpr uint8_t CTRL1_LITTLE_ENDIAN_AUTO_INC = 0x40;
constexpr uint8_t CTRL2_ACCEL_8G_125HZ = 0x26;
constexpr uint8_t CTRL3_GYRO_512DPS_112HZ = 0x56;
constexpr uint8_t CTRL7_ENABLE_ACCEL_GYRO = 0x03;
constexpr uint8_t CTRL7_DISABLE_SENSORS = 0x00;

constexpr float ACCEL_LSB_PER_G = 4096.0f;
constexpr float GYRO_LSB_PER_DPS = 64.0f;
constexpr uint32_t SAMPLE_INTERVAL_MS = 500;
constexpr float MOVING_GYRO_THRESHOLD_DPS = 20.0f;
constexpr float MOVING_ACCEL_DELTA_MG = 180.0f;
constexpr float ORIENTATION_THRESHOLD_MG = 650.0f;

Status imuStatus;
Sample latestSample;
uint32_t lastPollMs = 0;
uint32_t lastDiagLogMs = 0;

int16_t readInt16Le(const uint8_t *data) {
  return static_cast<int16_t>((static_cast<uint16_t>(data[1]) << 8) | data[0]);
}

bool write8(uint8_t reg, uint8_t value, const char *label) {
  return i2c::writeRegister8(imuStatus.address, reg, value, label, 3);
}

bool read8(uint8_t reg, uint8_t &value, const char *label) {
  return i2c::readRegisterBlock8(imuStatus.address, reg, &value, 1, label, 3);
}

bool readSequentialBytes(uint8_t firstReg, uint8_t *data, uint8_t len,
                         const char *label) {
  if (data == nullptr || len == 0) {
    return false;
  }
  for (uint8_t i = 0; i < len; i++) {
    if (!read8(firstReg + i, data[i], label)) {
      return false;
    }
  }
  return true;
}

void logRawDiagnostic(const char *reason) {
  if (!imuStatus.present || imuStatus.address == 0) {
    return;
  }

  uint8_t regs[12] = {};
  const bool regsOk = readSequentialBytes(REG_WHO_AM_I, regs, sizeof(regs),
                                          "QMI8658 diag regs");
  uint8_t status[3] = {};
  const bool statusOk = readSequentialBytes(REG_STATUS_INT, status,
                                            sizeof(status),
                                            "QMI8658 diag status");
  uint8_t data[12] = {};
  const bool dataOk = readSequentialBytes(REG_AX_L, data, sizeof(data),
                                          "QMI8658 diag data");
  uint8_t timestamp[3] = {};
  const bool timestampOk = readSequentialBytes(REG_TIMESTAMP_L, timestamp,
                                               sizeof(timestamp),
                                               "QMI8658 diag ts");

  Serial.printf("QMI8658 diag: reason=%s regsOk=%d who=0x%02X rev=0x%02X "
                "ctrl1=0x%02X ctrl2=0x%02X ctrl3=0x%02X ctrl5=0x%02X "
                "ctrl7=0x%02X statusOk=%d int=0x%02X st0=0x%02X st1=0x%02X "
                "tsOk=%d ts=%02X%02X%02X dataOk=%d "
                "acc=%02X %02X %02X %02X %02X %02X "
                "gyro=%02X %02X %02X %02X %02X %02X samples=%lu zero=%lu "
                "fail=%lu\n",
                reason ? reason : "-", regsOk, regs[REG_WHO_AM_I],
                regs[REG_REVISION], regs[REG_CTRL1], regs[REG_CTRL2],
                regs[REG_CTRL3], regs[REG_CTRL5], regs[REG_CTRL7], statusOk,
                status[0], status[1], status[2], timestampOk, timestamp[2],
                timestamp[1], timestamp[0], dataOk, data[0], data[1], data[2],
                data[3], data[4], data[5], data[6], data[7], data[8], data[9],
                data[10], data[11],
                static_cast<unsigned long>(imuStatus.sampleCount),
                static_cast<unsigned long>(imuStatus.zeroSamples),
                static_cast<unsigned long>(imuStatus.failedReads));
}

bool softReset(uint8_t address) {
  if (!i2c::writeRegister8(address, REG_RESET, RESET_VALUE, "QMI8658 reset",
                           3)) {
    return false;
  }

  const uint32_t startMs = millis();
  uint8_t resetResult = 0;
  while (millis() - startMs < 250) {
    delay(10);
    if (i2c::readRegister8(address, REG_RST_RESULT, resetResult,
                           "QMI8658 reset result", 1) &&
        resetResult == RST_RESULT_OK) {
      return true;
    }
  }

  Serial.printf("QMI8658: reset result timeout addr=0x%02X last=0x%02X\n",
                address, resetResult);
  return false;
}

bool detectAddress(uint8_t address, uint8_t &whoAmI, uint8_t &revision) {
  if (!i2c::probe(address, "QMI8658", 2)) {
    return false;
  }

  if (!softReset(address)) {
    return false;
  }

  if (!i2c::readRegister8(address, REG_WHO_AM_I, whoAmI, "QMI8658 whoami", 3)) {
    return false;
  }

  if (whoAmI != EXPECTED_WHO_AM_I) {
    Serial.printf("QMI8658: ignoring addr=0x%02X unexpected whoami=0x%02X\n",
                  address, whoAmI);
    return false;
  }

  if (!i2c::readRegister8(address, REG_REVISION, revision, "QMI8658 revision",
                          3)) {
    revision = 0;
  }

  return true;
}

Orientation classifyOrientation(const Sample &sample) {
  const float ax = sample.accelMg[0];
  const float ay = sample.accelMg[1];
  const float az = sample.accelMg[2];
  const float absX = fabsf(ax);
  const float absY = fabsf(ay);
  const float absZ = fabsf(az);

  if (absX < ORIENTATION_THRESHOLD_MG && absY < ORIENTATION_THRESHOLD_MG &&
      absZ < ORIENTATION_THRESHOLD_MG) {
    return Orientation::Unknown;
  }

  if (absZ >= absX && absZ >= absY) {
    return az >= 0.0f ? Orientation::FaceUp : Orientation::FaceDown;
  }
  if (absX >= absY) {
    return ax >= 0.0f ? Orientation::RightEdgeUp : Orientation::LeftEdgeUp;
  }
  return ay >= 0.0f ? Orientation::UsbUp : Orientation::UsbDown;
}

void updateDerivedState(const Sample &sample) {
  const float ax = sample.accelMg[0];
  const float ay = sample.accelMg[1];
  const float az = sample.accelMg[2];
  const float gx = sample.gyroDps[0];
  const float gy = sample.gyroDps[1];
  const float gz = sample.gyroDps[2];

  imuStatus.accelMagnitudeMg = sqrtf(ax * ax + ay * ay + az * az);
  imuStatus.vibrationDps = sqrtf(gx * gx + gy * gy + gz * gz);
  const bool accelMagnitudeLooksCalibrated = imuStatus.accelMagnitudeMg > 700.0f;
  imuStatus.moving = imuStatus.vibrationDps > MOVING_GYRO_THRESHOLD_DPS ||
                     (accelMagnitudeLooksCalibrated &&
                      fabsf(imuStatus.accelMagnitudeMg - 1000.0f) >
                          MOVING_ACCEL_DELTA_MG);
  imuStatus.orientation = classifyOrientation(sample);
}

bool configureSensor() {
  for (uint8_t attempt = 1; attempt <= 3; attempt++) {
    bool writeOk = write8(REG_CTRL7, CTRL7_DISABLE_SENSORS,
                          "QMI8658 disable sensors");
    delay(10);
    writeOk = writeOk &&
              write8(REG_CTRL1, CTRL1_LITTLE_ENDIAN_AUTO_INC, "QMI8658 ctrl1");
    delay(10);
    writeOk = writeOk &&
              write8(REG_CTRL2, CTRL2_ACCEL_8G_125HZ, "QMI8658 accel config");
    delay(10);
    writeOk = writeOk &&
              write8(REG_CTRL3, CTRL3_GYRO_512DPS_112HZ,
                     "QMI8658 gyro config");
    delay(10);
    writeOk = writeOk &&
              write8(REG_CTRL7, CTRL7_ENABLE_ACCEL_GYRO, "QMI8658 enable");
    delay(50);

    uint8_t ctrl1 = 0;
    uint8_t ctrl2 = 0;
    uint8_t ctrl3 = 0;
    uint8_t ctrl7 = 0;
    const bool readbackOk =
        read8(REG_CTRL1, ctrl1, "QMI8658 ctrl1 readback") &&
        read8(REG_CTRL2, ctrl2, "QMI8658 ctrl2 readback") &&
        read8(REG_CTRL3, ctrl3, "QMI8658 ctrl3 readback") &&
        read8(REG_CTRL7, ctrl7, "QMI8658 ctrl7 readback");
    if (writeOk && readbackOk && ctrl1 == CTRL1_LITTLE_ENDIAN_AUTO_INC &&
        ctrl2 == CTRL2_ACCEL_8G_125HZ && ctrl3 == CTRL3_GYRO_512DPS_112HZ &&
        (ctrl7 & CTRL7_ENABLE_ACCEL_GYRO) == CTRL7_ENABLE_ACCEL_GYRO) {
      return true;
    }

    Serial.printf("QMI8658: config attempt %u failed write=%d read=%d "
                  "ctrl1=0x%02X ctrl2=0x%02X ctrl3=0x%02X ctrl7=0x%02X\n",
                  attempt, writeOk, readbackOk, ctrl1, ctrl2, ctrl3, ctrl7);
  }
  logRawDiagnostic("config-failed");
  return false;
}

} // namespace

const Status &status() { return imuStatus; }

const Sample &lastSample() { return latestSample; }

const char *orientationName(Orientation orientation) {
  switch (orientation) {
  case Orientation::FaceUp:
    return "face-up";
  case Orientation::FaceDown:
    return "face-down";
  case Orientation::LeftEdgeUp:
    return "left-edge-up";
  case Orientation::RightEdgeUp:
    return "right-edge-up";
  case Orientation::UsbUp:
    return "usb-up";
  case Orientation::UsbDown:
    return "usb-down";
  case Orientation::Unknown:
  default:
    return "unknown";
  }
}

bool begin() {
  imuStatus = Status{};
  latestSample = Sample{};

  uint8_t whoAmI = 0;
  uint8_t revision = 0;
  uint8_t address = waveshare_board::QMI8658_ADDR_PRIMARY;
  if (!detectAddress(address, whoAmI, revision)) {
    address = waveshare_board::QMI8658_ADDR_FALLBACK;
    if (!detectAddress(address, whoAmI, revision)) {
      Serial.println("QMI8658: not found");
      return false;
    }
  }

  imuStatus.present = true;
  imuStatus.address = address;
  imuStatus.whoAmI = whoAmI;
  imuStatus.revision = revision;

  if (!configureSensor()) {
    Serial.printf("QMI8658: failed to configure addr=0x%02X\n", address);
    return false;
  }

  imuStatus.configured = true;
  Serial.printf("QMI8658: found addr=0x%02X whoami=0x%02X rev=0x%02X "
                "accel=8g@125Hz gyro=512dps@112Hz\n",
                imuStatus.address, imuStatus.whoAmI, imuStatus.revision);
#ifdef WAVESHARE_IMU_DEBUG_LOG
  logRawDiagnostic("configured");
#endif
  return true;
}

bool readSample(Sample &sample) {
  if (!imuStatus.configured) {
    return false;
  }

  uint8_t accelRegs[6] = {};
  if (!readSequentialBytes(REG_AX_L, accelRegs, sizeof(accelRegs),
                           "QMI8658 accel")) {
    imuStatus.dataValid = false;
    imuStatus.failedReads++;
    return false;
  }

  uint8_t gyroRegs[6] = {};
  if (!readSequentialBytes(REG_GX_L, gyroRegs, sizeof(gyroRegs),
                           "QMI8658 gyro")) {
    imuStatus.dataValid = false;
    imuStatus.failedReads++;
    return false;
  }

  const int16_t ax = readInt16Le(accelRegs);
  const int16_t ay = readInt16Le(accelRegs + 2);
  const int16_t az = readInt16Le(accelRegs + 4);
  const int16_t gx = readInt16Le(gyroRegs);
  const int16_t gy = readInt16Le(gyroRegs + 2);
  const int16_t gz = readInt16Le(gyroRegs + 4);
  const bool allZero = ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 &&
                       gz == 0;

  sample.accelMg[0] = (static_cast<float>(ax) * 1000.0f) / ACCEL_LSB_PER_G;
  sample.accelMg[1] = (static_cast<float>(ay) * 1000.0f) / ACCEL_LSB_PER_G;
  sample.accelMg[2] = (static_cast<float>(az) * 1000.0f) / ACCEL_LSB_PER_G;
  sample.gyroDps[0] = static_cast<float>(gx) / GYRO_LSB_PER_DPS;
  sample.gyroDps[1] = static_cast<float>(gy) / GYRO_LSB_PER_DPS;
  sample.gyroDps[2] = static_cast<float>(gz) / GYRO_LSB_PER_DPS;
  sample.sampledAtMs = millis();
  sample.timestamp = sample.sampledAtMs;

  latestSample = sample;
  imuStatus.sampleCount++;
  imuStatus.dataValid = !allZero;
  if (allZero) {
    imuStatus.zeroSamples++;
  }
  imuStatus.lastSampleMs = sample.sampledAtMs;
  updateDerivedState(sample);
  return true;
}

void process() {
  if (!imuStatus.configured) {
    return;
  }

  const uint32_t now = millis();
  if (now - lastPollMs < SAMPLE_INTERVAL_MS) {
    return;
  }
  lastPollMs = now;

  Sample sample;
  if (!readSample(sample)) {
    return;
  }

  if (!imuStatus.dataValid && imuStatus.zeroSamples > 0 &&
      (imuStatus.zeroSamples <= 3 || now - lastDiagLogMs >= 5000)) {
    lastDiagLogMs = now;
    logRawDiagnostic("zero-sample");
  }

#ifdef WAVESHARE_IMU_DEBUG_LOG
  static uint32_t lastLogMs = 0;
  if (now - lastLogMs >= 5000) {
    lastLogMs = now;
    Serial.printf("QMI8658: accel[mg]=%.0f,%.0f,%.0f gyro[dps]=%.1f,%.1f,%.1f "
                  "temp=%.1f orient=%s moving=%d samples=%lu failures=%lu\n",
                  sample.accelMg[0], sample.accelMg[1], sample.accelMg[2],
                  sample.gyroDps[0], sample.gyroDps[1], sample.gyroDps[2],
                  sample.temperatureC, orientationName(imuStatus.orientation),
                  imuStatus.moving,
                  static_cast<unsigned long>(imuStatus.sampleCount),
                  static_cast<unsigned long>(imuStatus.failedReads));
  }
#endif
}

} // namespace waveshare_board::imu

#endif // WAVESHARE_AMOLED_175
