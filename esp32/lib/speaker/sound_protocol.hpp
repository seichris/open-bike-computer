#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::speaker {

constexpr uint8_t DEFAULT_VOLUME_PERCENT = 70;

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

} // namespace waveshare_board::speaker
