#pragma once

#include <cstdint>

// Electrical identities, not marketing names. Unqualified peripherals stay off.
namespace board_traits {
#if defined(WAVESHARE_EPAPER_397)
constexpr bool epaper = true;
constexpr bool touch = false;
constexpr bool brightness = false;
constexpr bool qualifiedPowerControl = false;
constexpr uint16_t width = 480, height = 800;
constexpr int sda = 41, scl = 42;
constexpr int sdClock = 16, sdCommand = 17, sdData = 15;
constexpr int up = 4, center = 5, down = 6, boot = 0;
constexpr int epdClock = 11, epdMosi = 12, epdCs = 10;
constexpr int epdDc = 9, epdReset = 46, epdBusy = 3;
constexpr int audioMclk = 13, audioBclk = 14, audioLrck = 47;
constexpr int audioOut = 48, audioIn = 21, audioEnable = 39;
#else
constexpr bool epaper = false;
constexpr bool touch = true;
constexpr bool brightness = true;
constexpr bool qualifiedPowerControl = true;
#if defined(WAVESHARE_AMOLED_206)
constexpr uint16_t width = 410, height = 502;
#else
constexpr uint16_t width = 466, height = 466;
#endif
#endif
} // namespace board_traits
