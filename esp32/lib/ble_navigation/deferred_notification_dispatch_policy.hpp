#pragma once

#include <cstddef>

namespace ble_notification_dispatch_policy {

enum class TransportResult {
  Sent,
  Retry,
  Drop,
};

struct DispatchDecision {
  bool consumeHead = false;
  bool continueLater = false;
};

// The transport owns only one ATT notification attempt at a time. A transient
// host failure must leave the exact protected frame at the queue head so its
// authentication sequence is not skipped. Successful and terminal attempts
// consume the head; another owner/host handoff is required when more work
// remains so notifications are paced through NimBLE's finite TX buffers.
constexpr DispatchDecision decideAfterAttempt(TransportResult result,
                                              size_t queuedBefore) {
  if (queuedBefore == 0) {
    return {};
  }
  if (result == TransportResult::Retry) {
    return {false, true};
  }
  return {true, queuedBefore > 1};
}

} // namespace ble_notification_dispatch_policy
