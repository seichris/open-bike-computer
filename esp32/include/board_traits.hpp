#pragma once

#include <cstdint>

#include "../lib/board/board.hpp"

// Names the e-paper code adopted before the board files existed. Every value
// comes from the selected lib/board/boards definition; new code reads board::
// directly.
namespace board_traits {
constexpr bool epaper = board::identity::epaper;
constexpr bool touch = board::display::touch;
constexpr bool brightness = board::display::brightness;
constexpr bool qualifiedPowerControl = board::power::qualifiedPowerControl;
constexpr uint16_t width = board::display::width;
constexpr uint16_t height = board::display::height;
constexpr int sda = board::i2c::sda, scl = board::i2c::scl;
constexpr int sdClock = board::sd::clk, sdCommand = board::sd::cmd, sdData = board::sd::d0;
constexpr int boot = board::buttons::boot;
#if defined(WAVESHARE_EPAPER_397)
// Parts only the e-paper board carries.
constexpr int up = board::buttons::up, center = board::buttons::center, down = board::buttons::down;
constexpr int epdClock = board::epd::clock, epdMosi = board::epd::mosi, epdCs = board::epd::cs;
constexpr int epdDc = board::epd::dc, epdReset = board::epd::reset, epdBusy = board::epd::busy;
constexpr int audioMclk = board::audio::mclk, audioBclk = board::audio::bclk, audioLrck = board::audio::lrck;
constexpr int audioOut = board::audio::out, audioIn = board::audio::in, audioEnable = board::audio::enable;
#endif
} // namespace board_traits
