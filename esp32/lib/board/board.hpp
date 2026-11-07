#pragma once

// Selects the one board definition of this firmware target. Shared code reads
// the board:: data below or the pin names kept in include/hal.hpp; it never
// tests the target macro itself. docs/plans/board-support-architecture-plan.md
// describes the layout, and tools/tests/test_board_macro_confinement.py keeps
// target macros out of shared sources.
#if defined(WAVESHARE_AMOLED_175) + defined(WAVESHARE_AMOLED_206) + defined(WAVESHARE_EPAPER_397) != 1
#error "Define exactly one firmware target (WAVESHARE_AMOLED_175, WAVESHARE_AMOLED_206 or WAVESHARE_EPAPER_397)"
#elif defined(WAVESHARE_AMOLED_175)
#include "boards/waveshare_amoled_175.hpp"
#elif defined(WAVESHARE_AMOLED_206)
#include "boards/waveshare_amoled_206.hpp"
#elif defined(WAVESHARE_EPAPER_397)
#include "boards/waveshare_epaper_397.hpp"
#endif
