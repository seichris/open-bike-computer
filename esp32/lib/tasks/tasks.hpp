/**
 * @file tasks.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Core Tasks functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#ifdef HAS_HARDWARE_GPS
#include "gps.hpp"
#endif
#include "battery.hpp"
#include "lvgl.h"
// #include "mainScr.hpp"
#include "globalGpxDef.h"
#include "lvglFuncs.hpp"

#ifdef HAS_HARDWARE_GPS
void gpsTask(void *pvParameters);
void initGpsTask();
#endif

