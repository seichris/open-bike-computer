#pragma once

#include <cstddef>
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

// Speaker assets are stored as signed 16-bit mono PCM because both channels
// in the source recordings are identical. Expand them at playback time so the
// codec still receives the exact original interleaved stereo byte stream.
inline std::size_t expandMonoPcm16ToStereo(
    const uint8_t *input, std::size_t inputBytes, uint8_t *output,
    std::size_t outputFrameCapacity) {
  if (input == nullptr || output == nullptr || inputBytes < sizeof(int16_t) ||
      outputFrameCapacity == 0) {
    return 0;
  }
  std::size_t frames = inputBytes / sizeof(int16_t);
  if (frames > outputFrameCapacity)
    frames = outputFrameCapacity;
  for (std::size_t index = 0; index < frames; ++index) {
    const std::size_t inputOffset = index * sizeof(int16_t);
    const std::size_t outputOffset = index * 2 * sizeof(int16_t);
    output[outputOffset] = input[inputOffset];
    output[outputOffset + 1] = input[inputOffset + 1];
    output[outputOffset + 2] = input[inputOffset];
    output[outputOffset + 3] = input[inputOffset + 1];
  }
  return frames;
}

} // namespace waveshare_board::speaker
