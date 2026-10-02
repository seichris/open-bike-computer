#pragma once

#include <cstdint>

namespace sleep_audit {

struct RequestContext {
  uint32_t configuredTimeoutSeconds = 0;
  uint8_t displayState = 0;
  bool connected = false;
  bool audioPlaying = false;
};

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
// Call from Power::begin(), after boot diagnostics and before board init.
void begin();
// Record while I2C/storage are still available, before the recorder seals.
void requested(const RequestContext &context);
// These final-stage functions update RTC memory only. No log, I2C or SD work.
void recorderSealed(bool sealed);
void panelRequested(bool applied);
void peripheralsReturned();
void entering(int32_t wifiStop, int32_t bluetoothStop, int32_t bluedroidStop,
              int32_t wakeConfig, uint64_t wakeMask, uint8_t bootPinLevel);
#else
inline void begin() {}
inline void requested(const RequestContext &) {}
inline void recorderSealed(bool) {}
inline void panelRequested(bool) {}
inline void peripheralsReturned() {}
inline void entering(int32_t, int32_t, int32_t, int32_t, uint64_t, uint8_t) {}
#endif

} // namespace sleep_audit
