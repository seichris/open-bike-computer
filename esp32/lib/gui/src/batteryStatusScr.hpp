/**
 * @file batteryStatusScr.hpp
 * @brief Device and connected-phone battery status screen.
 */

#pragma once

#include "globalGuiDef.h"

void batteryStatusScr(lv_obj_t *screen);
void updateBatteryStatusEvent(lv_event_t *event);
