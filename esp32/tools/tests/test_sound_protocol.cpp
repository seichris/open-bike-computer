#include "../../lib/speaker/sound_protocol.hpp"

#include <cassert>
#include <cstdint>

using waveshare_board::speaker::PlaybackRequest;
using waveshare_board::speaker::PlayCommandResult;
using waveshare_board::speaker::PowerButtonHonkConfig;
using waveshare_board::speaker::PowerButtonHonkCommand;
using waveshare_board::speaker::Sound;
using waveshare_board::speaker::CAPABILITY_DEVICE_SOUNDS;
using waveshare_board::speaker::CAPABILITY_POWER_BUTTON_HONK;
using waveshare_board::speaker::CAPABILITY_POWER_BUTTON_HONK_ACK;
using waveshare_board::speaker::POWER_BUTTON_HONK_PAYLOAD_SIZE;
using waveshare_board::speaker::POWER_BUTTON_HONK_LEGACY_STATUS_SIZE;
using waveshare_board::speaker::POWER_BUTTON_HONK_STATUS_SIZE;
using waveshare_board::speaker::RESERVED_ROTATING_BELL_SOUND_ID;
using waveshare_board::speaker::capabilityFlags;
using waveshare_board::speaker::classifyPlayCommand;
using waveshare_board::speaker::classifyPowerButtonHonkCommand;
using waveshare_board::speaker::decodePlayPayload;
using waveshare_board::speaker::decodePowerButtonHonkPayload;
using waveshare_board::speaker::encodePowerButtonHonkPayload;
using waveshare_board::speaker::encodePowerButtonHonkStatus;
using waveshare_board::speaker::samePowerButtonHonkConfig;

int main() {
  PlaybackRequest request{};

  assert(capabilityFlags(false) == 0);
  assert(capabilityFlags(true) == CAPABILITY_DEVICE_SOUNDS);
  assert(capabilityFlags(false, true) == 0);
  assert(capabilityFlags(true, true) ==
         (CAPABILITY_DEVICE_SOUNDS | CAPABILITY_POWER_BUTTON_HONK));
  assert(capabilityFlags(false, true, true) == 0);
  assert(capabilityFlags(true, false, true) == CAPABILITY_DEVICE_SOUNDS);
  assert(capabilityFlags(true, true, true) ==
         (CAPABILITY_DEVICE_SOUNDS | CAPABILITY_POWER_BUTTON_HONK |
          CAPABILITY_POWER_BUTTON_HONK_ACK));

  const uint8_t legacy[] = {2};
  assert(decodePlayPayload(legacy, sizeof(legacy), request));
  assert(request.sound == Sound::PlasticBicycleHorn);
  assert(request.volumePercent == 70);

  const uint8_t minimum[] = {1, 0};
  assert(decodePlayPayload(minimum, sizeof(minimum), request));
  assert(request.sound == Sound::BellDing);
  assert(request.volumePercent == 0);

  const uint8_t maximum[] = {5, 100};
  assert(decodePlayPayload(maximum, sizeof(maximum), request));
  assert(request.sound == Sound::SqueezeHorn);
  assert(request.volumePercent == 100);

  const uint8_t unsupported[] = {4, 70};
  const uint8_t retired[] = {RESERVED_ROTATING_BELL_SOUND_ID, 70};
  const uint8_t excessiveVolume[] = {5, 101};
  const uint8_t extraByte[] = {5, 70, 0};
  assert(!decodePlayPayload(nullptr, 0, request));
  assert(!decodePlayPayload(unsupported, sizeof(unsupported), request));
  assert(!decodePlayPayload(retired, sizeof(retired), request));
  assert(!decodePlayPayload(excessiveVolume, sizeof(excessiveVolume), request));
  assert(!decodePlayPayload(extraByte, sizeof(extraByte), request));

  const uint8_t otherCommand[] = {'C', 'A', 'P', 'S'};
  const uint8_t validCommand[] = {'S', 'N', 'D', 'P', 5, 64};
  const uint8_t malformedCommand[] = {'S', 'N', 'D', 'P', 4, 70};
  assert(classifyPlayCommand(otherCommand, sizeof(otherCommand), true, request) ==
         PlayCommandResult::NotMatched);
  assert(classifyPlayCommand(validCommand, sizeof(validCommand), false, request) ==
         PlayCommandResult::RejectedUnauthenticated);
  assert(classifyPlayCommand(malformedCommand, sizeof(malformedCommand), true,
                             request) == PlayCommandResult::RejectedMalformed);
  assert(classifyPlayCommand(validCommand, sizeof(validCommand), true, request) ==
         PlayCommandResult::Accepted);
  assert(request.sound == Sound::SqueezeHorn);
  assert(request.volumePercent == 64);

  PowerButtonHonkConfig config{};
  const uint8_t enabledHonk[] = {1, 2, 85};
  const uint8_t disabledHonk[] = {0, 5, 0};
  const uint8_t invalidEnabled[] = {2, 2, 70};
  const uint8_t invalidHonkSound[] = {1, 4, 70};
  const uint8_t retiredHonkSound[] = {
      1, RESERVED_ROTATING_BELL_SOUND_ID, 70};
  const uint8_t invalidHonkVolume[] = {1, 5, 101};
  assert(decodePowerButtonHonkPayload(enabledHonk, sizeof(enabledHonk),
                                      config));
  assert(config.enabled);
  assert(config.sound == Sound::PlasticBicycleHorn);
  assert(config.volumePercent == 85);
  assert(decodePowerButtonHonkPayload(disabledHonk, sizeof(disabledHonk),
                                      config));
  assert(!config.enabled);
  assert(config.sound == Sound::SqueezeHorn);
  assert(config.volumePercent == 0);
  assert(!decodePowerButtonHonkPayload(invalidEnabled, sizeof(invalidEnabled),
                                       config));
  assert(!decodePowerButtonHonkPayload(invalidHonkSound,
                                       sizeof(invalidHonkSound), config));
  assert(!decodePowerButtonHonkPayload(retiredHonkSound,
                                       sizeof(retiredHonkSound), config));
  assert(!decodePowerButtonHonkPayload(invalidHonkVolume,
                                       sizeof(invalidHonkVolume), config));

  const PowerButtonHonkConfig persistedConfig{
      true, Sound::SqueezeHorn, 73};
  uint8_t persistedPayload[POWER_BUTTON_HONK_PAYLOAD_SIZE]{};
  assert(encodePowerButtonHonkPayload(persistedConfig, persistedPayload,
                                      sizeof(persistedPayload)));
  assert(persistedPayload[0] == 1);
  assert(persistedPayload[1] ==
         static_cast<uint8_t>(Sound::SqueezeHorn));
  assert(persistedPayload[2] == 73);
  PowerButtonHonkConfig reloadedConfig{};
  assert(decodePowerButtonHonkPayload(persistedPayload,
                                      sizeof(persistedPayload),
                                      reloadedConfig));
  assert(samePowerButtonHonkConfig(persistedConfig, reloadedConfig));
  reloadedConfig.volumePercent = 74;
  assert(!samePowerButtonHonkConfig(persistedConfig, reloadedConfig));
  reloadedConfig = persistedConfig;
  reloadedConfig.enabled = false;
  assert(!samePowerButtonHonkConfig(persistedConfig, reloadedConfig));
  reloadedConfig = persistedConfig;
  reloadedConfig.sound = Sound::PlasticBicycleHorn;
  assert(!samePowerButtonHonkConfig(persistedConfig, reloadedConfig));
  const PowerButtonHonkConfig invalidPersistedConfig{
      true, static_cast<Sound>(4), 73};
  assert(!encodePowerButtonHonkPayload(invalidPersistedConfig,
                                       persistedPayload,
                                       sizeof(persistedPayload)));
  assert(!encodePowerButtonHonkPayload(persistedConfig, nullptr,
                                       sizeof(persistedPayload)));
  const PowerButtonHonkCommand legacyStatusCommand{
      persistedConfig, 0, false};
  uint8_t legacyStatus[POWER_BUTTON_HONK_LEGACY_STATUS_SIZE]{};
  assert(encodePowerButtonHonkStatus(legacyStatusCommand, true, legacyStatus,
                                     sizeof(legacyStatus)));
  assert(legacyStatus[4] == 1);
  assert(legacyStatus[5] == 1);
  assert(legacyStatus[6] ==
         static_cast<uint8_t>(Sound::SqueezeHorn));
  assert(legacyStatus[7] == 73);

  const PowerButtonHonkCommand trackedStatusCommand{
      persistedConfig, 0xA1B2C3D4U, true};
  uint8_t applyStatus[POWER_BUTTON_HONK_STATUS_SIZE]{};
  assert(encodePowerButtonHonkStatus(trackedStatusCommand, true, applyStatus,
                                     sizeof(applyStatus)));
  assert(applyStatus[0] == 'S' && applyStatus[1] == 'N' &&
         applyStatus[2] == 'H' && applyStatus[3] == 'A');
  assert(applyStatus[4] == 0xD4);
  assert(applyStatus[5] == 0xC3);
  assert(applyStatus[6] == 0xB2);
  assert(applyStatus[7] == 0xA1);
  assert(applyStatus[8] == 1);
  assert(applyStatus[9] == 1);
  assert(applyStatus[10] ==
         static_cast<uint8_t>(Sound::SqueezeHorn));
  assert(applyStatus[11] == 73);
  assert(encodePowerButtonHonkStatus(trackedStatusCommand, false, applyStatus,
                                     sizeof(applyStatus)));
  assert(applyStatus[8] == 0);

  const uint8_t validHonkCommand[] = {'S', 'N', 'D', 'H', 1, 5, 55};
  const uint8_t trackedHonkCommand[] = {
      'S', 'N', 'D', 'H', 0xD4, 0xC3, 0xB2, 0xA1, 1, 5, 55};
  const uint8_t malformedHonkCommand[] = {'S', 'N', 'D', 'H', 1, 4, 55};
  PowerButtonHonkCommand command{};
  assert(classifyPowerButtonHonkCommand(otherCommand, sizeof(otherCommand),
                                        true, command) ==
         PlayCommandResult::NotMatched);
  assert(classifyPowerButtonHonkCommand(validHonkCommand,
                                        sizeof(validHonkCommand), false,
                                        command) ==
         PlayCommandResult::RejectedUnauthenticated);
  assert(classifyPowerButtonHonkCommand(malformedHonkCommand,
                                        sizeof(malformedHonkCommand), true,
                                        command) ==
         PlayCommandResult::RejectedMalformed);
  assert(classifyPowerButtonHonkCommand(validHonkCommand,
                                        sizeof(validHonkCommand), true,
                                        command) == PlayCommandResult::Accepted);
  assert(!command.hasRequestId);
  assert(command.config.enabled);
  assert(command.config.sound == Sound::SqueezeHorn);
  assert(command.config.volumePercent == 55);
  assert(classifyPowerButtonHonkCommand(trackedHonkCommand,
                                        sizeof(trackedHonkCommand), true,
                                        command) == PlayCommandResult::Accepted);
  assert(command.hasRequestId);
  assert(command.requestId == 0xA1B2C3D4U);
  assert(command.config.enabled);
  assert(command.config.sound == Sound::SqueezeHorn);
  assert(command.config.volumePercent == 55);
}
