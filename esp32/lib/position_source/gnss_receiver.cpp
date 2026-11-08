#include "gnss_receiver.hpp"

#include "../board/board.hpp"

#if BOARD_GNSS_FITTED

#include <Arduino.h>
#include <HardwareSerial.h>

#include "../gps/gps.hpp"
#include "../waveshare_board/tca9554.hpp"
#if PERSISTENT_RIDE_DIAGNOSTICS
#include "../ride_diagnostics/ride_diagnostics.hpp"
#endif

extern Gps gps;

namespace position_source::gnss_receiver {

namespace {
HardwareSerial port(board::gnss::uart);
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
GnssStatus state;
NmeaLineValidator validator;
BaudProbe probe;
bool validSentenceSinceSwitch = false;
bool probeReported = false;
bool fixReported = false;
uint32_t lastFixLogMs = 0;
constexpr uint32_t kFixLogIntervalMs = 30'000;
constexpr uint32_t kTaskStackBytes = 8192;

GnssStatus snapshot() {
  portENTER_CRITICAL(&mux);
  const GnssStatus copy = state;
  portEXIT_CRITICAL(&mux);
  return copy;
}

void printBoot(const char *probeState) {
  const GnssStatus s = snapshot();
  Serial.printf("BOOT_GNSS schema=1 fitted=1 module=%s uart=%u rx=%u tx=%u "
                "reset=%s baud=%lu probe=%s sentences=%lu invalid=%lu\n",
                position_source::moduleName(),
                static_cast<unsigned>(board::gnss::uart),
                static_cast<unsigned>(board::gnss::rx),
                static_cast<unsigned>(board::gnss::tx),
                board::gnss::resetViaExpander ? "expander" : "none",
                static_cast<unsigned long>(s.baud), probeState,
                static_cast<unsigned long>(s.validSentences),
                static_cast<unsigned long>(s.invalidSentences));
}

void recordDiagnostic(const char *event, bool available, bool fixValid,
                      uint32_t sentences, uint32_t invalid) {
#if PERSISTENT_RIDE_DIAGNOSTICS
  char fields[160] = {};
  snprintf(fields, sizeof(fields),
           "{\"source\":\"gnss\",\"available\":%s,\"fixValid\":%s,"
           "\"eventCount\":%lu,\"droppedCount\":%lu}",
           available ? "true" : "false", fixValid ? "true" : "false",
           static_cast<unsigned long>(sentences),
           static_cast<unsigned long>(invalid));
  ride_diagnostics::record(ride_diagnostics::Level::Info, "gnss", event,
                           fields);
#else
  (void)event;
  (void)available;
  (void)fixValid;
  (void)sentences;
  (void)invalid;
#endif
}

void releaseReset() {
  if (!board::gnss::resetViaExpander)
    return;
  // The receiver's RESET is active low. Driving the expander pin high keeps
  // the module running without restarting its acquisition.
  const bool ok =
      waveshare_board::tca9554::configureOutput(board::gnss::resetExpanderPin) &&
      waveshare_board::tca9554::setPin(board::gnss::resetExpanderPin, true);
  Serial.printf("GNSS: reset line %s\n",
                ok ? "released through the expander"
                   : "not controllable (expander write failed)");
}

void readerTask(void *) {
  for (;;) {
    bool readAny = false;
    while (port.available() > 0) {
      readAny = true;
      const char c = static_cast<char>(port.read());
      const NmeaLineValidator::Event event = validator.feed(c);
      if (event == NmeaLineValidator::Event::Valid) {
        validSentenceSinceSwitch = true;
        portENTER_CRITICAL(&mux);
        ++state.validSentences;
        state.lastSentenceMs = millis();
        portEXIT_CRITICAL(&mux);
      } else if (event == NmeaLineValidator::Event::Invalid) {
        portENTER_CRITICAL(&mux);
        ++state.invalidSentences;
        portEXIT_CRITICAL(&mux);
      }
      GPS.decode(c);
    }
    while (GPS.available()) {
      fix = GPS.read();
      gps.getGPSData();
      const bool fixValid =
          fix.status >= gps_fix::STATUS_STD && static_cast<bool>(fix.valid.location);
      const uint32_t nowMs = millis();
      portENTER_CRITICAL(&mux);
      ++state.fixes;
      state.fixValid = fixValid;
      state.satellites = fix.satellites;
      if (fixValid)
        state.lastFixMs = nowMs;
      portEXIT_CRITICAL(&mux);
      position_source::noteGnssFix(nowMs, fixValid);
      if (fixValid && (!fixReported ||
                       static_cast<uint32_t>(nowMs - lastFixLogMs) >= kFixLogIntervalMs)) {
        const GnssStatus s = snapshot();
#if FIRMWARE_DIAGNOSTICS
        Serial.printf("GNSS: fix sats=%u lat=%.6f lon=%.6f speed=%u heading=%s%u\n",
                      static_cast<unsigned>(s.satellites), gps.gpsData.latitude,
                      gps.gpsData.longitude,
                      static_cast<unsigned>(gps.gpsData.speed),
                      gps.gpsData.headingValid ? "" : "invalid:",
                      static_cast<unsigned>(gps.gpsData.heading));
#endif
        recordDiagnostic(fixReported ? "fix_checkpoint" : "fix", true, true,
                         s.validSentences, s.invalidSentences);
        fixReported = true;
        lastFixLogMs = nowMs;
      }
    }
    const uint32_t nowMs = millis();
    if (probe.poll(nowMs, validSentenceSinceSwitch)) {
      validSentenceSinceSwitch = false;
      port.updateBaudRate(probe.current());
      portENTER_CRITICAL(&mux);
      state.baud = probe.current();
      portEXIT_CRITICAL(&mux);
      printBoot("retry");
    }
    if (probe.locked && !probeReported) {
      probeReported = true;
      portENTER_CRITICAL(&mux);
      state.probeLocked = true;
      portEXIT_CRITICAL(&mux);
      printBoot("ok");
      const GnssStatus s = snapshot();
      recordDiagnostic("probe", true, false, s.validSentences, s.invalidSentences);
    }
    vTaskDelay(readAny ? 1 : pdMS_TO_TICKS(20));
  }
}
}  // namespace

void begin() {
  portENTER_CRITICAL(&mux);
  state.fitted = true;
  portEXIT_CRITICAL(&mux);
  releaseReset();
  probe.begin(board::gnss::baud, millis());
  port.setRxBufferSize(1024);
  port.begin(probe.current(), SERIAL_8N1, board::gnss::rx, board::gnss::tx);
  portENTER_CRITICAL(&mux);
  state.portOpen = true;
  state.baud = probe.current();
  portEXIT_CRITICAL(&mux);
  printBoot("pending");
}

void startTask() {
  xTaskCreatePinnedToCore(readerTask, "GNSS", kTaskStackBytes, nullptr, 1,
                          nullptr, 0);
}

GnssStatus status() { return snapshot(); }

}  // namespace position_source::gnss_receiver

#else  // No receiver on this board.

namespace position_source::gnss_receiver {

void begin() {}
void startTask() {}
GnssStatus status() { return GnssStatus{}; }

}  // namespace position_source::gnss_receiver

#endif
