#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::speaker {

constexpr uint8_t DEFAULT_VOLUME_PERCENT = 70;
constexpr uint8_t CAPABILITY_DEVICE_SOUNDS = 1U << 0;
constexpr uint8_t CAPABILITY_POWER_BUTTON_HONK = 1U << 1;
constexpr uint8_t CAPABILITY_POWER_BUTTON_HONK_ACK = 1U << 2;
constexpr size_t POWER_BUTTON_HONK_PAYLOAD_SIZE = 3;
constexpr size_t POWER_BUTTON_HONK_REQUEST_ID_SIZE = 4;
constexpr size_t POWER_BUTTON_HONK_COMMAND_PAYLOAD_SIZE =
    POWER_BUTTON_HONK_REQUEST_ID_SIZE + POWER_BUTTON_HONK_PAYLOAD_SIZE;
constexpr size_t POWER_BUTTON_HONK_LEGACY_STATUS_SIZE = 8;
constexpr size_t POWER_BUTTON_HONK_STATUS_SIZE =
    4 + POWER_BUTTON_HONK_REQUEST_ID_SIZE + 1 + POWER_BUTTON_HONK_PAYLOAD_SIZE;

enum class Sound : uint8_t {
  BellDing = 1,
  PlasticBicycleHorn = 2,
  SqueezeHorn = 5,
};

// Sound ID 3 was the removed rotating-bell recording. Keep it unassigned so
// persisted settings and older clients fail closed instead of selecting a
// different sound.
constexpr uint8_t RESERVED_ROTATING_BELL_SOUND_ID = 3;

struct PlaybackRequest {
  Sound sound;
  uint8_t volumePercent;
};

struct PowerButtonHonkConfig {
  bool enabled;
  Sound sound;
  uint8_t volumePercent;
};

struct PowerButtonHonkCommand {
  PowerButtonHonkConfig config;
  uint32_t requestId;
  bool hasRequestId;
};

inline bool samePowerButtonHonkConfig(const PowerButtonHonkConfig &lhs,
                                      const PowerButtonHonkConfig &rhs) {
  return lhs.enabled == rhs.enabled && lhs.sound == rhs.sound &&
         lhs.volumePercent == rhs.volumePercent;
}

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
  case Sound::SqueezeHorn:
    return true;
  }
  return false;
}

inline uint8_t capabilityFlags(bool deviceSoundsAvailable,
                               bool powerButtonHonkAvailable = false,
                               bool powerButtonHonkAckAvailable = false) {
  if (!deviceSoundsAvailable) {
    return 0;
  }
  uint8_t flags = CAPABILITY_DEVICE_SOUNDS;
  if (powerButtonHonkAvailable) {
    flags |= CAPABILITY_POWER_BUTTON_HONK;
    if (powerButtonHonkAckAvailable) {
      flags |= CAPABILITY_POWER_BUTTON_HONK_ACK;
    }
  }
  return flags;
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

inline bool decodePowerButtonHonkPayload(const uint8_t *data, size_t length,
                                         PowerButtonHonkConfig &config) {
  if (data == nullptr || length != POWER_BUTTON_HONK_PAYLOAD_SIZE ||
      data[0] > 1) {
    return false;
  }

  const Sound sound = static_cast<Sound>(data[1]);
  if (!isKnownSound(sound) || data[2] > 100) {
    return false;
  }

  config = {data[0] == 1, sound, data[2]};
  return true;
}

inline bool encodePowerButtonHonkPayload(const PowerButtonHonkConfig &config,
                                         uint8_t *data, size_t length) {
  if (data == nullptr || length != POWER_BUTTON_HONK_PAYLOAD_SIZE ||
      !isKnownSound(config.sound) || config.volumePercent > 100) {
    return false;
  }

  data[0] = config.enabled ? 1 : 0;
  data[1] = static_cast<uint8_t>(config.sound);
  data[2] = config.volumePercent;
  return true;
}

inline bool decodePowerButtonHonkCommandPayload(
    const uint8_t *data, size_t length, PowerButtonHonkCommand &command) {
  if (data == nullptr) {
    return false;
  }
  if (length == POWER_BUTTON_HONK_PAYLOAD_SIZE) {
    command.requestId = 0;
    command.hasRequestId = false;
    return decodePowerButtonHonkPayload(data, length, command.config);
  }
  if (length != POWER_BUTTON_HONK_COMMAND_PAYLOAD_SIZE) {
    return false;
  }

  command.requestId = static_cast<uint32_t>(data[0]) |
                      (static_cast<uint32_t>(data[1]) << 8) |
                      (static_cast<uint32_t>(data[2]) << 16) |
                      (static_cast<uint32_t>(data[3]) << 24);
  command.hasRequestId = true;
  return decodePowerButtonHonkPayload(
      data + POWER_BUTTON_HONK_REQUEST_ID_SIZE,
      length - POWER_BUTTON_HONK_REQUEST_ID_SIZE, command.config);
}

inline size_t powerButtonHonkStatusSize(
    const PowerButtonHonkCommand &command) {
  return command.hasRequestId ? POWER_BUTTON_HONK_STATUS_SIZE
                              : POWER_BUTTON_HONK_LEGACY_STATUS_SIZE;
}

inline bool encodePowerButtonHonkStatus(const PowerButtonHonkCommand &command,
                                        bool applied, uint8_t *data,
                                        size_t length) {
  const size_t expectedLength = powerButtonHonkStatusSize(command);
  if (data == nullptr || length != expectedLength) {
    return false;
  }

  data[0] = 'S';
  data[1] = 'N';
  data[2] = 'H';
  data[3] = 'A';
  size_t offset = 4;
  if (command.hasRequestId) {
    data[offset++] = static_cast<uint8_t>(command.requestId);
    data[offset++] = static_cast<uint8_t>(command.requestId >> 8);
    data[offset++] = static_cast<uint8_t>(command.requestId >> 16);
    data[offset++] = static_cast<uint8_t>(command.requestId >> 24);
  }
  data[offset++] = applied ? 1 : 0;
  return encodePowerButtonHonkPayload(command.config, data + offset,
                                      length - offset);
}

inline PlayCommandResult classifyPowerButtonHonkCommand(
    const uint8_t *data, size_t length, bool authenticated,
    PowerButtonHonkCommand &command) {
  constexpr uint8_t prefix[] = {'S', 'N', 'D', 'H'};
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
  if (!decodePowerButtonHonkCommandPayload(
          data + sizeof(prefix), length - sizeof(prefix), command)) {
    return PlayCommandResult::RejectedMalformed;
  }
  return PlayCommandResult::Accepted;
}

} // namespace waveshare_board::speaker
