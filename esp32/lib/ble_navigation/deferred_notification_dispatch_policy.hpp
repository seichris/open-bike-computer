#pragma once

#include <cstddef>

namespace ble_notification_dispatch_policy {

// Notifications share MSYS with incoming ATT requests and their responses.
// Leave room for a 512-byte prepared write (up to three retained fragments at
// the phone's 185-byte MTU), its current RX/response, and ACL/control headroom.
// Queue admission alone is insufficient: NimBLE can accept a notification into
// its L2CAP backlog even when the controller cannot transmit it yet.
constexpr int kCommandBufferReserve = 6;

constexpr bool canAllocateNotification(int freeBuffers) {
  return freeBuffers > kCommandBufferReserve;
}

constexpr bool canDispatchNotification(int freeBuffersAfterAllocation) {
  return freeBuffersAfterAllocation >= kCommandBufferReserve;
}

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
