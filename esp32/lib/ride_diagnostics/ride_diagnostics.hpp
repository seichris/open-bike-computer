#pragma once

#include <cstddef>
#include <cstdint>

class Storage;

namespace ride_diagnostics {

enum class Level : uint8_t {
  Debug = 0,
  Info = 1,
  Warning = 2,
  Error = 3,
};

struct Stats {
  uint32_t enqueued;
  uint32_t written;
  uint32_t dropped;
  uint32_t storageErrors;
  uint16_t queueDepth;
  uint16_t maxQueueDepth;
  bool storageAvailable;
};

constexpr std::size_t kMaximumEventBytes = 768;
constexpr std::size_t kQueueCapacity = 32;
constexpr std::size_t kChunkBytes = 256 * 1024;
constexpr std::size_t kRetentionBytes = 32 * 1024 * 1024;
constexpr uint8_t kRetentionBoots = 20;

void begin(Storage &storage, uint32_t bootSequence, uint32_t firmwareFingerprint);
void process(uint32_t nowMs);

bool record(Level level, const char *category, const char *event,
            const char *fieldsJson = "{}");
bool markIssue(const char *code);
bool bindCapture(const char *captureId);
void clearCapture();
const char *captureId();
Stats stats();
uint32_t currentBootSequence();
uint32_t currentActiveChunk();
bool isClosedChunk(uint32_t boot, uint32_t chunk);

} // namespace ride_diagnostics
