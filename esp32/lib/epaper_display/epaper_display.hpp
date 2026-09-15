#pragma once

#include "epaper_raster.hpp"

namespace epaper {
struct Status {
  uint32_t queued = 0, transmitted = 0, presented = 0;
  uint32_t pairingGeneration = 0, completedAtMs = 0;
  uint32_t fullCount = 0, partialCount = 0, failures = 0;
  uint32_t unchangedCount = 0, discarded = 0, context = 0;
  uint32_t sleepCount = 0, wakeCount = 0, sleepFailures = 0;
  uint32_t lastWaveformMs = 0, lastWaveformDurationMs = 0;
  uint32_t maxFullDurationMs = 0, maxPartialDurationMs = 0;
  uint32_t compositionGeneration = 0;
  uint32_t acceptedGpsSequence = 0;
  uint32_t baseCameraSequence = 0;
  uint16_t partialsSinceFull = 0;
  bool lastPresentationHadWaveform = false;
  bool lastWaveformFull = false;
  bool busy = false, fault = false, sleeping = false;
};
void begin();
bool submit(const uint16_t *rgb);
// UI owner only. Snapshots the logical navigation identities that the next
// complete LVGL frame represents without coupling the display worker back to
// the GUI/map libraries.
void setFrameProvenance(uint32_t acceptedGpsSequence,
                        uint32_t baseCameraSequence);
void setPairingGeneration(uint32_t generation);
uint32_t pairingGeneration();
bool pairingPresented();
void prioritize();
// Cancels queued content for a hard screen/session/history replacement and
// requests a successor composition. Ordinary route-window and maneuver data
// revisions remain compatible. A waveform already on the glass must finish;
// its completion cannot authorize new UI.
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
