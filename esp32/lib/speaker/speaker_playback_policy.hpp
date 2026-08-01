#pragma once

#include <cstdint>

namespace waveshare_board::speaker {

constexpr uint32_t kPlaybackRequestIdMask = 0x7FFFFFFFU;

struct PlaybackCompletion {
  uint32_t requestId;
  bool succeeded;
};

enum class TrackedPlaybackResult : uint8_t {
  Pending,
  Succeeded,
  Failed,
  Superseded,
};

constexpr uint32_t encodePlaybackCompletion(uint32_t requestId,
                                            bool succeeded) {
  return ((requestId & kPlaybackRequestIdMask) << 1U) |
         (succeeded ? 1U : 0U);
}

constexpr PlaybackCompletion decodePlaybackCompletion(uint32_t token) {
  return {token >> 1U, (token & 1U) != 0U};
}

constexpr bool playbackRequestIdAfter(uint32_t candidate,
                                      uint32_t reference) {
  const uint32_t distance =
      (candidate - reference) & kPlaybackRequestIdMask;
  return distance != 0U && distance < (1U << 30U);
}

constexpr TrackedPlaybackResult classifyPlaybackCompletion(
    uint32_t expectedRequestId, PlaybackCompletion completion) {
  if (expectedRequestId == 0U || completion.requestId == 0U ||
      playbackRequestIdAfter(expectedRequestId, completion.requestId)) {
    return TrackedPlaybackResult::Pending;
  }
  if (completion.requestId != expectedRequestId) {
    return TrackedPlaybackResult::Superseded;
  }
  return completion.succeeded ? TrackedPlaybackResult::Succeeded
                              : TrackedPlaybackResult::Failed;
}

constexpr bool playbackRequestLifecycleSucceeded(bool playbackSucceeded,
                                                 bool cleanupRequired,
                                                 bool cleanupSucceeded) {
  return playbackSucceeded && (!cleanupRequired || cleanupSucceeded);
}

} // namespace waveshare_board::speaker
