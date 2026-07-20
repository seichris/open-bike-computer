#pragma once

#include "sound_protocol.hpp"

#include <Arduino.h>

namespace waveshare_board::speaker {

bool begin();
bool isAvailable();
bool requestPlay(Sound sound,
                 uint8_t volumePercent = DEFAULT_VOLUME_PERCENT);
bool isSupported(Sound sound);
bool isPowerButtonHonkAvailable();
bool getPowerButtonHonkConfig(PowerButtonHonkConfig &config);
bool configurePowerButtonHonk(const PowerButtonHonkConfig &config);
void handlePowerButtonHonkPress();

} // namespace waveshare_board::speaker
