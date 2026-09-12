#pragma once

#include "epaper_raster.hpp"

namespace epaper {
struct Status {
  uint32_t queued = 0, transmitted = 0, presented = 0;
  uint32_t pairingGeneration = 0, completedAtMs = 0;
  uint32_t fullCount = 0, partialCount = 0, failures = 0;
  uint32_t discarded = 0, context = 0;
  bool busy = false, fault = false, sleeping = false;
};
void begin();
bool submit(const uint16_t *rgb);
void setPairingGeneration(uint32_t generation);
uint32_t pairingGeneration();
bool pairingPresented();
void prioritize();
// Cancels queued content for a departed screen, route or maneuver. A waveform
// already on the glass must finish; its completion cannot authorize new UI.
void invalidateContext();
Status status();
void sleep();
void wake();
// UI task only. Delivers physical completion after checking semantic identity.
void poll();
#ifdef EPAPER_DISPLAY_TEST
void diagnosticPattern(int delta);
void diagnosticFault(bool enabled);
#endif
} // namespace epaper
