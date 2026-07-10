#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::speaker {

constexpr uint8_t DEFAULT_VOLUME_PERCENT = 70;
constexpr uint8_t CAPABILITY_DEVICE_SOUNDS = 1U << 0;

enum class Sound : uint8_t {
  BellDing = 1,
  PlasticBicycleHorn = 2,
  RotatingBicycleBell = 3,
  SqueezeHorn = 5,
};

struct PlaybackRequest {
  Sound sound;
  uint8_t volumePercent;
};

enum class PlayCommandResult {
  NotMatched,
  RejectedUnauthenticated,
  RejectedMalformed,
  Accepted,
};

inline bool isKnownSound(Sound sound) {
  switch (sound) {
  case Sound::BellDing:
  case Sound::PlasticBicycleHorn:
  case Sound::RotatingBicycleBell:
  case Sound::SqueezeHorn:
    return true;
  }
  return false;
}

inline uint8_t capabilityFlags(bool deviceSoundsAvailable) {
  return deviceSoundsAvailable ? CAPABILITY_DEVICE_SOUNDS : 0;
}

inline bool decodePlayPayload(const uint8_t *data, size_t length,
                              PlaybackRequest &request) {
  if (data == nullptr || (length != 1 && length != 2)) {
    return false;
  }

  const Sound sound = static_cast<Sound>(data[0]);
  const uint8_t volumePercent =
      length == 2 ? data[1] : DEFAULT_VOLUME_PERCENT;
  if (!isKnownSound(sound) || volumePercent > 100) {
    return false;
  }

  request = {sound, volumePercent};
  return true;
}

inline PlayCommandResult classifyPlayCommand(const uint8_t *data, size_t length,
                                             bool authenticated,
                                             PlaybackRequest &request) {
  constexpr uint8_t prefix[] = {'S', 'N', 'D', 'P'};
  if (data == nullptr || length < sizeof(prefix)) {
    return PlayCommandResult::NotMatched;
  }
  for (size_t i = 0; i < sizeof(prefix); i++) {
    if (data[i] != prefix[i]) {
      return PlayCommandResult::NotMatched;
    }
  }
  if (!authenticated) {
    return PlayCommandResult::RejectedUnauthenticated;
  }
  if (!decodePlayPayload(data + sizeof(prefix), length - sizeof(prefix),
                         request)) {
    return PlayCommandResult::RejectedMalformed;
  }
  return PlayCommandResult::Accepted;
}

} // namespace waveshare_board::speaker
