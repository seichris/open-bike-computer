#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace device_transfer::lifecycle_resources {
// Only fixed program phases enter diagnostics. Request paths, errors, network
// names, credentials, certificate pins and artifact strings never enter it.
inline bool checkpoint(const char *phase) {
  if (phase == nullptr) return false;
  constexpr const char *phases[] = {
      "transfer_entry", "network_ready", "commit_granted", "grant_released",
      "map_terminal", "before_map_activation", "after_map_activation",
      "boot_selected", "cancelled", "network_stopped", "owner_released",
      "shutdown_requested", "worker_failed", "operation_selected", "ota_begin"};
  for (const char *allowed : phases)
    if (std::strcmp(phase, allowed) == 0) return true;
  return false;
}
inline const char *modeName(const char *mode) {
  constexpr const char *modes[] = {"map", "firmware", "diagnostics", "debug"};
  for (const char *allowed : modes)
    if (mode != nullptr && std::strcmp(mode, allowed) == 0) return allowed;
  return "unknown";
}
inline bool uuid(const char *value) {
  if (value == nullptr) return false;
  const auto length = std::strlen(value);
  // OTA receipts use compact UUID hex; map clients may use hyphenated UUIDs.
  if (length != 32 && length != 36) return false;
  for (unsigned i = 0; i < length; ++i) {
    const char c = value[i];
    if (length == 36 && (i == 8 || i == 13 || i == 18 || i == 23)) {
      if (c != '-') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                 (c >= 'A' && c <= 'F'))) return false;
  }
  return true;
}
// Empty or invalid map headers on a generic grant must not erase the OTA
// operation previously bound by its validated consumer adapter.
inline bool bindOperation(char (&current)[37], const char *operation) {
  if (!uuid(operation)) return false;
  std::snprintf(current, sizeof(current), "%s", operation);
  return true;
}
struct Snapshot {
  uint32_t cycle = 0, sample = 0, generation = 0;
  uint32_t free[3] = {}, largest[3] = {}, minimumFree[3] = {}, minimumLargest[3] = {};
  uint32_t tlsStack = 0, ownerStack = 0, rendererStack = 0, stackAvailableMask = 0;
  bool cleanupFailed = false;
  char mode[12] = {}, operation[37] = {};
};
// The existing recorder accepts fewer than 320 bytes. Keep each event below
// that bound even at UINT32_MAX and never emit truncated JSON.
inline bool metadata(char (&out)[320], const Snapshot &s, const char *phase) {
  if (!checkpoint(phase)) return false;
  const int size = std::snprintf(out, sizeof(out),
      "{\"attempt\":%lu,\"sampleCount\":%lu,\"generation\":%lu,"
      "\"mode\":\"%s\",\"phase\":\"%s\",\"operationId\":\"%s\",\"cleanupFailed\":%s}",
      (unsigned long)s.cycle, (unsigned long)s.sample, (unsigned long)s.generation,
      modeName(s.mode), phase, uuid(s.operation) ? s.operation : "",
      s.cleanupFailed ? "true" : "false");
  return size > 0 && static_cast<unsigned>(size) < sizeof(out);
}
inline bool pool(char (&out)[320], const Snapshot &s, unsigned index) {
  if (index >= 3) return false;
  constexpr const char *names[] = {"internal", "dma", "psram"};
  const int size = std::snprintf(out, sizeof(out),
      "{\"attempt\":%lu,\"sampleCount\":%lu,\"scope\":\"%s\","
      "\"freeBytes\":%lu,\"largestBytes\":%lu,\"minimumFreeBytes\":%lu,\"minimumLargestBytes\":%lu}",
      (unsigned long)s.cycle, (unsigned long)s.sample, names[index],
      (unsigned long)s.free[index], (unsigned long)s.largest[index],
      (unsigned long)s.minimumFree[index], (unsigned long)s.minimumLargest[index]);
  return size > 0 && static_cast<unsigned>(size) < sizeof(out);
}
inline bool stacks(char (&out)[320], const Snapshot &s) {
  const int size = std::snprintf(out, sizeof(out),
      "{\"attempt\":%lu,\"sampleCount\":%lu,\"tlsStackBytes\":%lu,\"ownerStackBytes\":%lu,\"rendererStackBytes\":%lu,\"stackAvailableMask\":%lu}",
      (unsigned long)s.cycle, (unsigned long)s.sample,
      (unsigned long)s.tlsStack, (unsigned long)s.ownerStack, (unsigned long)s.rendererStack,
      (unsigned long)s.stackAvailableMask);
  return size > 0 && static_cast<unsigned>(size) < sizeof(out);
}
} // namespace device_transfer::lifecycle_resources
