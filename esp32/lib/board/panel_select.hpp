#pragma once

// Includes the panel header of this firmware target: the board definition
// that board.hpp selects names its panel (board::display::panel, mirrored by
// BOARD_PANEL), and each panel maps to one header in lib/panel. Shared code
// includes lib/panel/panelSelect.hpp, which forwards here. Every include is
// written out by relative path so that PlatformIO's dependency finder and
// tools/tests/test_ldf_include_paths.py can follow it; never compute one.
#include "board.hpp"

#if !defined(BOARD_PANEL)
#error "The board definition names no panel; define BOARD_PANEL"
#elif BOARD_PANEL == BOARD_PANEL_CO5300_AMOLED
#include "../panel/WAVESHARE_AMOLED_175.hpp"
#elif BOARD_PANEL == BOARD_PANEL_SSD1677_EPAPER
// An e-paper-named header also stays behind the e-paper board macro: CI
// builds a change to an e-paper-named file for the e-paper images only, and
// .github/scripts/tests/test_firmware_profile_coverage.py holds every include
// of one to that guard. Another board with this panel needs that routing first.
#ifdef WAVESHARE_EPAPER_397
#include "../panel/WAVESHARE_EPAPER_397.hpp"
#else
#error "The SSD1677 panel header compiles only into WAVESHARE_EPAPER_397 images"
#endif
#else
#error "The board definition names a panel without a header in panel_select.hpp"
#endif
