#include "../../lib/speaker/speaker_playback_policy.hpp"

#include <cassert>
#include <cstdint>

using waveshare_board::speaker::PlaybackCompletion;
using waveshare_board::speaker::TrackedPlaybackResult;
using waveshare_board::speaker::classifyPlaybackCompletion;
using waveshare_board::speaker::decodePlaybackCompletion;
using waveshare_board::speaker::encodePlaybackCompletion;
using waveshare_board::speaker::expandMonoPcm16ToStereo;
using waveshare_board::speaker::kPlaybackRequestIdMask;
using waveshare_board::speaker::playbackRequestLifecycleSucceeded;

int main() {
  const PlaybackCompletion success =
      decodePlaybackCompletion(encodePlaybackCompletion(42U, true));
  assert(success.requestId == 42U);
  assert(success.succeeded);
  assert(classifyPlaybackCompletion(42U, success) ==
         TrackedPlaybackResult::Succeeded);

  const PlaybackCompletion failure =
      decodePlaybackCompletion(encodePlaybackCompletion(43U, false));
  assert(failure.requestId == 43U);
  assert(!failure.succeeded);
  assert(classifyPlaybackCompletion(43U, failure) ==
         TrackedPlaybackResult::Failed);

  assert(classifyPlaybackCompletion(44U, failure) ==
         TrackedPlaybackResult::Pending);
  assert(classifyPlaybackCompletion(42U, failure) ==
         TrackedPlaybackResult::Superseded);
  assert(classifyPlaybackCompletion(1U, {0U, false}) ==
         TrackedPlaybackResult::Pending);
  assert(classifyPlaybackCompletion(0U, success) ==
         TrackedPlaybackResult::Pending);

  const PlaybackCompletion beforeWrap{kPlaybackRequestIdMask, true};
  const PlaybackCompletion afterWrap{1U, true};
  assert(classifyPlaybackCompletion(1U, beforeWrap) ==
         TrackedPlaybackResult::Pending);
  assert(classifyPlaybackCompletion(kPlaybackRequestIdMask, afterWrap) ==
         TrackedPlaybackResult::Superseded);

  assert(playbackRequestLifecycleSucceeded(true, false, false));
  assert(playbackRequestLifecycleSucceeded(true, true, true));
  assert(!playbackRequestLifecycleSucceeded(true, true, false));
  assert(!playbackRequestLifecycleSucceeded(false, false, true));

  const uint8_t mono[] = {0x34, 0x12, 0x00, 0x80, 0xff, 0x7f};
  uint8_t stereo[12]{};
  assert(expandMonoPcm16ToStereo(mono, sizeof(mono), stereo, 3) == 3);
  const uint8_t expectedStereo[] = {
      0x34, 0x12, 0x34, 0x12, 0x00, 0x80,
      0x00, 0x80, 0xff, 0x7f, 0xff, 0x7f};
  for (std::size_t index = 0; index < sizeof(stereo); ++index)
    assert(stereo[index] == expectedStereo[index]);
  assert(expandMonoPcm16ToStereo(mono, sizeof(mono), stereo, 1) == 1);
  assert(expandMonoPcm16ToStereo(nullptr, sizeof(mono), stereo, 3) == 0);

  return 0;
}
