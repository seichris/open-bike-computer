#pragma once

#include <cstdint>

namespace firmware_maintenance::policy {

constexpr uint32_t kRequestMagic = 0x4d41544f; // "OTAM" little-endian
constexpr uint16_t kRequestSchema = 1;
constexpr uint32_t kSoftwareResetReason = 3;
constexpr uint32_t kAwaitingAuthenticationTimeoutMs = 2U * 60U * 1000U;
constexpr uint32_t kTransferInactivityTimeoutMs = 90U * 1000U;
constexpr uint32_t kBootButtonExitHoldMs = 2U * 1000U;

struct BootButtonExitState {
  bool releasedSinceBoot = false;
  bool pressStarted = false;
  uint32_t pressedAtMs = 0;
};

// GPIO0 can be low during the reset that enters maintenance. Only a fresh
// release and hold in this boot is an intentional request to leave it.
constexpr bool bootButtonExitRequested(BootButtonExitState &state,
                                       bool pressed, uint32_t nowMs) {
  if (!pressed) {
    state.releasedSinceBoot = true;
    state.pressStarted = false;
    return false;
  }
  if (!state.releasedSinceBoot)
    return false;
  if (!state.pressStarted) {
    state.pressStarted = true;
    state.pressedAtMs = nowMs;
    return false;
  }
  return nowMs - state.pressedAtMs >= kBootButtonExitHoldMs;
}

enum class ResourcePhase : uint8_t {
  BeforeWorker = 0,
  BeforeListener,
};

enum class ResourceAdmission : uint8_t {
  Admitted = 0,
  InternalFreeLow,
  InternalLargestLow,
  DmaFreeLow,
  DmaLargestLow,
};

struct ResourceSnapshot {
  uint32_t internalFree;
  uint32_t internalLargest;
  uint32_t dmaFree;
  uint32_t dmaLargest;
};

// Candidate fail-closed budgets. Physical qualification records the observed
// margins and may raise these floors; it must never silently lower them below
// the authenticated-control emergency reserve.
constexpr ResourceSnapshot kBeforeWorkerMinimum{96U * 1024U, 48U * 1024U,
                                                64U * 1024U, 32U * 1024U};
constexpr ResourceSnapshot kBeforeListenerMinimum{48U * 1024U, 24U * 1024U,
                                                  32U * 1024U, 16U * 1024U};

constexpr ResourceSnapshot minimumFor(ResourcePhase phase) {
  return phase == ResourcePhase::BeforeWorker ? kBeforeWorkerMinimum
                                               : kBeforeListenerMinimum;
}

constexpr ResourceAdmission admit(ResourcePhase phase,
                                  const ResourceSnapshot &available) {
  const ResourceSnapshot minimum = minimumFor(phase);
  if (available.internalFree < minimum.internalFree)
    return ResourceAdmission::InternalFreeLow;
  if (available.internalLargest < minimum.internalLargest)
    return ResourceAdmission::InternalLargestLow;
  if (available.dmaFree < minimum.dmaFree)
    return ResourceAdmission::DmaFreeLow;
  if (available.dmaLargest < minimum.dmaLargest)
    return ResourceAdmission::DmaLargestLow;
  return ResourceAdmission::Admitted;
}

constexpr const char *resourceAdmissionCode(ResourceAdmission admission) {
  switch (admission) {
  case ResourceAdmission::Admitted:
    return "admitted";
  case ResourceAdmission::InternalFreeLow:
    return "maintenance_internal_free_low";
  case ResourceAdmission::InternalLargestLow:
    return "maintenance_internal_largest_low";
  case ResourceAdmission::DmaFreeLow:
    return "maintenance_dma_free_low";
  case ResourceAdmission::DmaLargestLow:
    return "maintenance_dma_largest_low";
  }
  return "maintenance_resource_unknown";
}

constexpr bool authenticationTimedOut(uint32_t elapsedMs, bool authenticated) {
  return !authenticated && elapsedMs >= kAwaitingAuthenticationTimeoutMs;
}

constexpr bool transferTimedOut(uint32_t nowMs, uint32_t lastUsefulTrafficMs,
                                bool transferEnabled,
                                bool authorizedRequestInProgress) {
  return transferEnabled && !authorizedRequestInProgress &&
         nowMs - lastUsefulTrafficMs >= kTransferInactivityTimeoutMs;
}

struct Request {
  uint32_t magic;
  uint16_t schema;
  uint16_t size;
  uint32_t firmwareFingerprint;
  uint32_t correlation;
  uint32_t checksum;
};

static_assert(sizeof(Request) == 20,
              "maintenance request is an RTC-memory wire format");

constexpr uint32_t mixByte(uint32_t hash, uint8_t value) {
  return (hash ^ value) * 16777619U;
}

constexpr uint32_t mixU16(uint32_t hash, uint16_t value) {
  hash = mixByte(hash, static_cast<uint8_t>(value));
  return mixByte(hash, static_cast<uint8_t>(value >> 8));
}

constexpr uint32_t mixU32(uint32_t hash, uint32_t value) {
  hash = mixU16(hash, static_cast<uint16_t>(value));
  return mixU16(hash, static_cast<uint16_t>(value >> 16));
}

constexpr uint32_t checksum(const Request &request) {
  uint32_t hash = 2166136261U;
  hash = mixU32(hash, request.magic);
  hash = mixU16(hash, request.schema);
  hash = mixU16(hash, request.size);
  hash = mixU32(hash, request.firmwareFingerprint);
  return mixU32(hash, request.correlation);
}

inline Request make(uint32_t firmwareFingerprint, uint32_t correlation) {
  Request request{kRequestMagic, kRequestSchema,
                  static_cast<uint16_t>(sizeof(Request)),
                  firmwareFingerprint,
                  correlation == 0 ? 1U : correlation,
                  0};
  request.checksum = checksum(request);
  return request;
}

constexpr bool valid(const Request &request) {
  return request.magic == kRequestMagic && request.schema == kRequestSchema &&
         request.size == sizeof(Request) && request.firmwareFingerprint != 0 &&
         request.correlation != 0 && request.checksum == checksum(request);
}

inline bool consume(Request &stored, uint32_t firmwareFingerprint,
                    uint32_t resetReason, uint32_t &correlation) {
  const Request candidate = stored;
  stored = {};
  correlation = 0;
  if (resetReason != kSoftwareResetReason || !valid(candidate) ||
      candidate.firmwareFingerprint != firmwareFingerprint) {
    return false;
  }
  correlation = candidate.correlation;
  return true;
}

} // namespace firmware_maintenance::policy
