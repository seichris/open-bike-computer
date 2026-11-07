/**
 * @file rideTelemetryText.hpp
 * @brief Label helpers of the Ride Stats screen, shared with its family
 *        presentation files (rideStatsAmoled.cpp / rideStatsEpaper.cpp).
 *
 * Defined in rideTelemetryScr.cpp, where they read the screen's current
 * layout; the workout-stats host harness compiles that text as is.
 */

#pragma once

#include "globalGuiDef.h"
#include "rideMetricTypography.hpp"
#include "rideTelemetryLayout.hpp"

ride_metric_typography::Role metricFontRole();
ride_telemetry_layout::Rect metricValueRect(
    const ride_telemetry_layout::Rect &metric);
void setLabelIfChanged(lv_obj_t *label, const char *text);
void setMetricTitleIfChanged(lv_obj_t *label, const char *text,
                             const ride_telemetry_layout::Rect &rect);
void applyMetricText(lv_obj_t *label, const char *text,
                     const ride_telemetry_layout::Rect &rect,
                     const lv_font_t *font, lv_text_align_t align);
void setMetricValueIfChanged(lv_obj_t *label, const char *text,
                             const ride_telemetry_layout::Rect &rect,
                             ride_metric_typography::Role role,
                             const lv_font_t *sharedFont);
void setHeartValue(lv_obj_t *label, lv_obj_t *heart, const char *text,
                   const ride_telemetry_layout::Rect &metric, bool available,
                   const lv_font_t *sharedFont);
