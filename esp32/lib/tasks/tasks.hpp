/**
 * @file tasks.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Core Tasks functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "gps.hpp"
#ifdef BME280
#include "bme.hpp"
#endif
#include "battery.hpp"
#ifdef ENABLE_COMPASS
#include "compass.hpp"
#endif
#include "lvgl.h"
#ifndef DISABLE_CLI
#include "cli.hpp"
#endif
// #include "mainScr.hpp"
#include "globalGpxDef.h"
#include "lvglFuncs.hpp"

#define TASK_SLEEP_PERIOD_MS 5

void gpsTask(void *pvParameters);
void initGpsTask();

#ifndef DISABLE_CLI
void cliTask(void *param);
void initCLITask();
#endif
