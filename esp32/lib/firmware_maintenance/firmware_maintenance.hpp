#pragma once

#include <cstdint>

namespace firmware_maintenance {

enum class Stage : uint8_t {
  Normal = 0,
  RebootPending,
  AwaitingAuthentication,
  NetworkStarting,
  Ready,
  Receiving,
  Verifying,
  Committing,
  Rebooting,
  Cancelling,
  Failed,
};

constexpr uint32_t kOverallDeadlineMs = 10U * 60U * 1000U;

const char *stageName(Stage stage);
bool active();
Stage stage();
uint32_t correlation();
uint32_t activeSinceMs();

// The request is bound to the exact running firmware identity and is consumed
// only after the immediately following software reset. It carries no secret or
// authorization state.
bool requestNextBoot(uint32_t firmwareFingerprint);
bool consumeForCurrentBoot(uint32_t firmwareFingerprint, uint32_t resetReason);

void setStage(Stage stage);
void requestExit();
bool exitRequested();

} // namespace firmware_maintenance
