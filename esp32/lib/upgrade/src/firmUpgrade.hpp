/**
 * @file firmUpgrade.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Firmware upgrade from SD functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#ifndef DISABLE_OTA_UPGRADE

#include <Update.h>
#include "tft.hpp"
#include "lvgl.h"
#include "upgradeScr.hpp"
#include "storage.hpp"

static const char *upgrdFile PROGMEM = "/sdcard/firmware.bin"; // Firmware upgrade file

bool checkFileUpgrade();
void onUpgrdStart();
void drawProgressBar(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint8_t percent, uint16_t frameColor, uint16_t barColor);
void onUpgrdProcess(size_t currSize, size_t totalSize);
void onUpgrdEnd();

#else

// Stub functions when OTA upgrade is disabled
inline bool checkFileUpgrade() { return false; }
inline void onUpgrdStart() {}
inline void onUpgrdEnd() {}

#endif // DISABLE_OTA_UPGRADE