/**
 * @file waitingScr.hpp
 * @brief  LVGL - Waiting for App screen
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "globalGuiDef.h"

extern lv_obj_t *waitingScreen;              // Waiting for App Screen
extern volatile bool gpsReceivedFromApp;     // Flag: GPS received via BLE
extern volatile bool pendingTransitionToMap; // Flag: Transition to map pending

void createWaitingScr();
void checkPendingMapTransition(); // Called from main loop
