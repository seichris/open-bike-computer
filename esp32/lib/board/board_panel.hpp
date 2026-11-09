#pragma once

#include <cstdint>

// Display panels a board may carry, each with its own header in lib/panel.
// A board file names its panel in board::display::panel and repeats it in the
// BOARD_PANEL macro, because only the preprocessor can choose a header;
// panel_select.hpp includes the header by that macro.
#define BOARD_PANEL_CO5300_AMOLED 1
#define BOARD_PANEL_SSD1677_EPAPER 2

namespace board {

enum class Panel : uint8_t {
  // CO5300 AMOLED over QSPI through Arduino_GFX:
  // lib/panel/WAVESHARE_AMOLED_175.hpp, shared by the 1.75 and the 2.06.
  co5300Amoled = BOARD_PANEL_CO5300_AMOLED,
  // SSD1677 e-paper over SPI: lib/panel/WAVESHARE_EPAPER_397.hpp.
  ssd1677Epaper = BOARD_PANEL_SSD1677_EPAPER,
};

}  // namespace board
