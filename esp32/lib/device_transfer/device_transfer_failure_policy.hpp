#pragma once

#include <cstddef>
#include <cstdint>

namespace device_transfer::failure_policy {

enum class TlsWriteOutcome : uint8_t {
  PositiveComplete, PositivePartial, WantRead, WantWrite, RawZero, Fatal
};

inline TlsWriteOutcome classifyTlsWrite(int32_t result, size_t requested,
                                        int32_t wantRead, int32_t wantWrite) {
  if (result > 0)
    return static_cast<size_t>(result) < requested
               ? TlsWriteOutcome::PositivePartial
               : TlsWriteOutcome::PositiveComplete;
  if (result == wantRead)
    return TlsWriteOutcome::WantRead;
  if (result == wantWrite)
    return TlsWriteOutcome::WantWrite;
  return result == 0 ? TlsWriteOutcome::RawZero : TlsWriteOutcome::Fatal;
}

inline bool noProgressExpired(uint32_t nowMs, uint32_t lastProgressMs,
                              uint32_t timeoutMs) {
  return nowMs - lastProgressMs >= timeoutMs;
}

inline bool fileReadFailed(size_t returned, bool error) {
  return returned == 0 || error;
}

inline uint8_t authorizationBits(bool enabled, bool tokenPresent,
                                 bool tokenMatches, bool generationMatches,
                                 bool bleBound, bool diagnosticsModeMatches) {
  return (enabled ? 1U : 0U) | (tokenPresent ? 2U : 0U) |
         (tokenMatches ? 4U : 0U) | (generationMatches ? 8U : 0U) |
         (bleBound ? 16U : 0U) | (diagnosticsModeMatches ? 32U : 0U);
}

} // namespace device_transfer::failure_policy
