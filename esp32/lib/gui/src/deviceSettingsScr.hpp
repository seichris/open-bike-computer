/**
 * @file deviceSettingsScr.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Device Settings Screen
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "globalGuiDef.h"
#include "upgradeScr.hpp"
#include "lvglSetup.hpp"
#include "firmUpgrade.hpp"
#include "ride_automation_runtime.hpp"

static lv_obj_t *deviceSettingsOptions;

static void deviceSettingsEvent(lv_event_t *event);
static void brightnessEvent(lv_event_t *e);
static void upgradeEvent(lv_event_t *event);
void createDeviceSettingsScr();
