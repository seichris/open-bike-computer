/**
 * @file panelSelect.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief Panel model select
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "WAVESHARE_AMOLED_175.hpp"
#elif defined(WAVESHARE_EPAPER_397)
#include "WAVESHARE_EPAPER_397.hpp"
#else
#error "No Panel defined!"
#endif
