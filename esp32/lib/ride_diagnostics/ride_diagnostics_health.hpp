#pragma once
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_format.hpp"
#include <cstdio>

namespace ride_diagnostics::detail {
// Shared by the actual producer and the executable regression fixture. A
// vocabulary drift must fail the fixture, rather than silently dropping health.
inline bool formatHealthFields(const Stats &snapshot, const char *reason,
                               char *out, std::size_t capacity) {
  if (out == nullptr || capacity == 0 || reason == nullptr)
    return false;
  const std::size_t reasonLength = std::strlen(reason);
  if (reasonLength == 0 || reasonLength > 32)
    return false;
  for (std::size_t i = 0; i < reasonLength; ++i) {
    const char c = reason[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
      return false;
  }
  const int bytes = std::snprintf(
      out, capacity,
      "{\"reason\":\"%s\",\"enqueuedCount\":%lu,\"writtenCount\":%lu,"
      "\"droppedCount\":%lu,\"storageErrorCount\":%lu,\"queueDepth\":%u,"
      "\"maxQueueDepth\":%u,\"available\":%s,\"recorderReady\":%s}",
      reason, static_cast<unsigned long>(snapshot.enqueued),
      static_cast<unsigned long>(snapshot.written),
      static_cast<unsigned long>(snapshot.dropped),
      static_cast<unsigned long>(snapshot.storageErrors),
      static_cast<unsigned>(snapshot.queueDepth),
      static_cast<unsigned>(snapshot.maxQueueDepth),
      snapshot.storageAvailable ? "true" : "false",
      snapshot.recorderReady ? "true" : "false");
  return bytes > 0 && static_cast<std::size_t>(bytes) < capacity &&
         validateFieldsJson(out, static_cast<std::size_t>(bytes));
}
} // namespace ride_diagnostics::detail
