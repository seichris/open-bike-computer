#pragma once

#include "sound_protocol.hpp"

#include <Arduino.h>

namespace waveshare_board::speaker {

bool begin();
bool requestPlay(Sound sound,
                 uint8_t volumePercent = DEFAULT_VOLUME_PERCENT);
bool isSupported(Sound sound);

} // namespace waveshare_board::speaker
