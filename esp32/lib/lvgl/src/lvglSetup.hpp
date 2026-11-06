/**
 * @file lvglSetup.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL Screen implementation
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "globalGpxDef.h"
#include "lvgl_private.h"
#include "tasks.hpp"
#include "deviceSettingsScr.hpp"
#include "mapSettingsScr.hpp"
#include "maps.hpp"
#include "notifyBar.hpp"
#include "settingsScr.hpp"
#include "splashScr.hpp"
#include "waitingScr.hpp"

/**
 * @brief Default display driver definition
 *
 */
static uint32_t objectColor = 0x303030;

void IRAM_ATTR displayFlush(lv_display_t *disp, const lv_area_t *area,
                            uint8_t *px_map);
void IRAM_ATTR touchRead(lv_indev_t *indev_driver, lv_indev_data_t *data);
void applyModifyTheme(lv_theme_t *th, lv_obj_t *obj);
void modifyTheme();
void initLVGL();
void loadMainScreen();
